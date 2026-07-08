///|
/// A user-created port forwarding rule persisted to disk.
///
/// Named `PortMappingRule` to disambiguate from the existing NAT-related
/// `PortMapping` struct in `connection.mbt`.
struct PortMappingRule {
  id : String
  peer_id : String
  remote_protocol : String
  remote_host : String
  remote_port : Int
  local_host : String
  local_port : Int
  enabled : Bool
  created_at : UInt64
  note : String?
} derive(Debug, ToJson, FromJson, Eq)

///|
struct PortMappingFile {
  version : Int
  mappings : Array[PortMappingRule]
} derive(Debug, ToJson, FromJson)

///|
/// Runtime cache of the mapping store.
///
/// - `mappings` – authoritative persisted list (kept in memory to avoid re-reading the
///   file on every access; mutations write-through to disk).
/// - `active_rules` – projection of `mappings` into `PortForwardForwardRule`, consumed
///   by [refresh_port_forward_registry] to decide which listeners to run.
/// - `store_path` – resolved on first use; `None` until then.
struct PortMappingStoreState {
  mappings : Array[PortMappingRule]
  mut active_rules : Array[PortForwardForwardRule]?
  mut store_path : String?
  mut loaded : Bool
}

///|
let port_mapping_store_state : PortMappingStoreState = {
  mappings: [],
  active_rules: None,
  store_path: None,
  loaded: false,
}

///|
/// Return the resolved on-disk path for the mapping store.
///
/// Resolution rules (first hit wins):
///   1. `${config.upload_dir}/port_mappings.json` when upload_dir is set.
///   2. `${HOME}/.msgtier/port_mappings.json` on unix.
///   3. `./port_mappings.json` (cwd) as ultimate fallback.
fn resolve_port_mapping_store_path() -> String {
  match port_mapping_store_state.store_path {
    Some(p) => p
    None => {
      let path = match get_config().upload_dir {
        Some(dir) if dir != "" =>
          if dir.has_suffix("/") {
            dir + "port_mappings.json"
          } else {
            dir + "/port_mappings.json"
          }
        _ =>
          match @sys.get_env_var("HOME") {
            Some(home) if home != "" =>
              (if home.has_suffix("/") {
                home + ".msgtier/"
              } else {
                home + "/.msgtier/"
              }) +
              "port_mappings.json"
            _ => "port_mappings.json"
          }
      }
      port_mapping_store_state.store_path = Some(path)
      path
    }
  }
}

///|
/// Ensure the parent directory of `path` exists (best-effort, ignore errors).
async fn ensure_port_mapping_parent_dir(path : String) -> Unit {
  match find_last_char_index(path, '/') {
    Some(idx) => {
      let parent = path[:idx].to_owned()
      if parent != "" {
        @fs.mkdir(parent, permission=0o755) catch {
          _ => ()
        }
      }
    }
    None => ()
  }
}

///|
fn find_last_char_index(s : String, target : Char) -> Int? {
  let target_int = target.to_int()
  let mut i = s.length()
  while i > 0 {
    i = i - 1
    if s[i].to_int() == target_int {
      return Some(i)
    }
  }
  None
}

///|
/// Rebuild `active_rules` from the current mappings.
///
/// Only mappings whose protocol maps to a listener kind we run (tcp/udp/http) and
/// whose `enabled == true` produce a rule.
fn recompute_port_mapping_active_rules() -> Unit {
  let rules : Array[PortForwardForwardRule] = []
  for m in port_mapping_store_state.mappings {
    if !m.enabled {
      continue
    }
    let protocol = m.remote_protocol
    if !(protocol == "tcp" || protocol == "udp" || protocol == "http") {
      continue
    }
    rules.push({
      id: m.id,
      protocol,
      peer_id: m.peer_id,
      listen_host: m.local_host,
      listen_port: m.local_port,
      enabled: Some(true),
    })
  }
  port_mapping_store_state.active_rules = Some(rules)
}

///|
/// Load persisted mappings from disk.  Missing file, invalid JSON, or wrong
/// version all silently produce an empty store and log a warning — the app
/// must never fail to start because of a corrupted mapping file.
async fn load_port_mapping_store() -> Unit {
  if port_mapping_store_state.loaded {
    return
  }
  port_mapping_store_state.loaded = true
  let path = resolve_port_mapping_store_path()
  let text = @fs.read_file(path).text() catch {
    _ => {
      recompute_port_mapping_active_rules()
      return
    }
  }
  let parsed : Json = @json.parse(text) catch {
    _ => {
      log_warn("port_mapping_store: invalid JSON in \{path}")
      recompute_port_mapping_active_rules()
      return
    }
  }
  let file : PortMappingFile = @json.from_json(parsed) catch {
    _ => {
      log_warn("port_mapping_store: schema mismatch in \{path}")
      recompute_port_mapping_active_rules()
      return
    }
  }
  if file.version != 1 {
    log_warn("port_mapping_store: unsupported version \{file.version}")
    recompute_port_mapping_active_rules()
    return
  }
  port_mapping_store_state.mappings.clear()
  for m in file.mappings {
    port_mapping_store_state.mappings.push(m)
  }
  recompute_port_mapping_active_rules()
  log_info(
    "port_mapping_store: loaded \{port_mapping_store_state.mappings.length()} rules from \{path}",
  )
}

///|
/// Persist current mappings to disk atomically (temp file + rename).
async fn save_port_mapping_store() -> Unit {
  let path = resolve_port_mapping_store_path()
  ensure_port_mapping_parent_dir(path)
  let file : PortMappingFile = {
    version: 1,
    mappings: port_mapping_store_state.mappings,
  }
  let payload = file.to_json().stringify(indent=2)
  let tmp_path = path + ".tmp"
  @fs.write_file(
    tmp_path,
    @utf8.encode(payload),
    create_mode=@fs.CreateOrTruncate,
    permission=0o644,
  ) catch {
    e => {
      log_warn("port_mapping_store: write \{tmp_path} failed: \{e}")
      return
    }
  }
  @fs.rename(tmp_path, path) catch {
    e =>
      log_warn("port_mapping_store: rename \{tmp_path} -> \{path} failed: \{e}")
  }
}

///|
/// Return a copy of the current mappings.
fn list_port_mapping_rules() -> Array[PortMappingRule] {
  let out : Array[PortMappingRule] = []
  for m in port_mapping_store_state.mappings {
    out.push(m)
  }
  out
}

///|
/// Try to bind on host:port to check availability.  Success closes the socket
/// immediately.  Errors count as "port in use / unavailable".
async fn is_local_port_available(
  host : String,
  port : Int,
  protocol : String,
) -> Bool {
  let addr_str = make_port_forward_socket_addr(host, port)
  let addr = @socket.Addr::parse(addr_str) catch { _ => return false }
  if protocol == "udp" {
    let server = @socket.UdpServer(addr) catch { _ => return false }
    server.close()
    true
  } else {
    let server = @socket.TcpServer(addr, reuse_addr=true) catch {
      _ => return false
    }
    server.close()
    true
  }
}

///|
/// Test whether the given local port is already claimed by one of our mappings.
fn is_local_port_used_by_mappings(port : Int, host : String) -> Bool {
  for m in port_mapping_store_state.mappings {
    if m.local_port == port && m.local_host == host {
      return true
    }
  }
  false
}

///|
/// Suggest a free local port for the requested remote target.
///
/// Preferred: `remote_port + 40000` (wraps to `remote_port + 20000` on
/// overflow).  On conflict, walk forward up to 200 candidates skipping any
/// port already used by another mapping.
async fn allocate_local_port(
  remote_port : Int,
  host : String,
  protocol : String,
) -> Int? {
  let base = if remote_port + 40000 <= 65534 {
    remote_port + 40000
  } else {
    remote_port + 20000
  }
  let mut attempt = 0
  let mut candidate = base
  while attempt < 200 {
    if candidate > 65534 {
      candidate = 45000 + attempt
    }
    if !is_local_port_used_by_mappings(candidate, host) &&
      is_local_port_available(host, candidate, protocol) {
      return Some(candidate)
    }
    candidate = candidate + 1
    attempt = attempt + 1
  }
  None
}

///|
suberror PortMappingError {
  DuplicatePort(Int)
  InvalidProtocol(String)
  InvalidPort(Int)
  AllocationFailed
  NotFound(String)
} derive(Debug)

///|
/// Add a new mapping.  Returns the freshly-created rule.
///
/// - `local_port_opt = None` triggers auto-allocation.
/// - Fails with `DuplicatePort` if a mapping already claims `local_port`.
/// - Fails with `InvalidProtocol` on anything other than tcp/udp/http.
async fn create_port_mapping_rule(
  peer_id : String,
  remote_protocol : String,
  remote_host : String,
  remote_port : Int,
  local_host_opt : String?,
  local_port_opt : Int?,
  note : String?,
) -> PortMappingRule {
  if normalize_port_forward_protocol(remote_protocol) is None {
    raise PortMappingError::InvalidProtocol(remote_protocol)
  }
  if !is_valid_port_forward_port(remote_port) {
    raise PortMappingError::InvalidPort(remote_port)
  }
  let local_host = local_host_opt.unwrap_or("127.0.0.1")
  let protocol = normalize_port_forward_protocol(remote_protocol).unwrap_or(
    "tcp",
  )
  let local_port = match local_port_opt {
    Some(p) => {
      if !is_valid_port_forward_port(p) {
        raise PortMappingError::InvalidPort(p)
      }
      if is_local_port_used_by_mappings(p, local_host) {
        raise PortMappingError::DuplicatePort(p)
      }
      p
    }
    None =>
      match allocate_local_port(remote_port, local_host, protocol) {
        Some(p) => p
        None => raise PortMappingError::AllocationFailed
      }
  }
  let id = @nanoid.nanoid().unwrap_or(@env.now().to_string())
  let rule : PortMappingRule = {
    id,
    peer_id,
    remote_protocol: protocol,
    remote_host,
    remote_port,
    local_host,
    local_port,
    enabled: true,
    created_at: @env.now(),
    note,
  }
  port_mapping_store_state.mappings.push(rule)
  recompute_port_mapping_active_rules()
  save_port_mapping_store()
  if app_state.root is Some(root) {
    refresh_port_forward_registry(root)
  }
  rule
}

///|
/// Remove a mapping by id.
async fn delete_port_mapping_rule(id : String) -> Unit {
  let mut found = false
  let kept : Array[PortMappingRule] = []
  for m in port_mapping_store_state.mappings {
    if m.id == id {
      found = true
    } else {
      kept.push(m)
    }
  }
  if !found {
    raise PortMappingError::NotFound(id)
  }
  port_mapping_store_state.mappings.clear()
  for m in kept {
    port_mapping_store_state.mappings.push(m)
  }
  recompute_port_mapping_active_rules()
  save_port_mapping_store()
  if app_state.root is Some(root) {
    refresh_port_forward_registry(root)
  }
}

///|
/// Toggle / rename a mapping.  Passing None for a field leaves it unchanged.
async fn update_port_mapping_rule(
  id : String,
  enabled : Bool?,
  note : String?,
) -> PortMappingRule {
  let mut updated : PortMappingRule? = None
  let out : Array[PortMappingRule] = []
  for m in port_mapping_store_state.mappings {
    if m.id == id {
      let next : PortMappingRule = {
        ..m,
        enabled: enabled.unwrap_or(m.enabled),
        note: match note {
          Some(_) => note
          None => m.note
        },
      }
      updated = Some(next)
      out.push(next)
    } else {
      out.push(m)
    }
  }
  match updated {
    Some(rule) => {
      port_mapping_store_state.mappings.clear()
      for m in out {
        port_mapping_store_state.mappings.push(m)
      }
      recompute_port_mapping_active_rules()
      save_port_mapping_store()
      if app_state.root is Some(root) {
        refresh_port_forward_registry(root)
      }
      rule
    }
    None => raise PortMappingError::NotFound(id)
  }
}

///|
/// One-time init: load mappings, then start listeners for every enabled rule.
async fn init_port_mapping_store(root : @async.TaskGroup[Unit]) -> Unit {
  load_port_mapping_store()
  refresh_port_forward_registry(root)
}
