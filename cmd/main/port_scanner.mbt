///|
struct LocalPortEntry {
  protocol : String
  bind_addr : String
  port : Int
  process_name : String?
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Order two entries deterministically so that diff results are stable.
fn compare_local_port_entry(a : LocalPortEntry, b : LocalPortEntry) -> Int {
  if a.protocol < b.protocol {
    -1
  } else if a.protocol > b.protocol {
    1
  } else if a.port < b.port {
    -1
  } else if a.port > b.port {
    1
  } else if a.bind_addr < b.bind_addr {
    -1
  } else if a.bind_addr > b.bind_addr {
    1
  } else {
    let an = a.process_name.unwrap_or("")
    let bn = b.process_name.unwrap_or("")
    if an < bn {
      -1
    } else if an > bn {
      1
    } else {
      0
    }
  }
}

///|
fn local_port_entry_key(entry : LocalPortEntry) -> String {
  entry.protocol + "|" + entry.port.to_string() + "|" + entry.bind_addr
}

///|
struct PortScannerState {
  mut last_scan : Array[LocalPortEntry]
  mut initialized : Bool
  broadcast_set : Map[String, Bool]
  remote_ports_by_peer : Map[String, Array[LocalPortEntry]]
  remote_last_updated : Map[String, UInt64]
  /// Timestamp (ms) of the last snapshot we sent to each peer. Used by the
  /// scheduler to decide when to (re)send a full snapshot vs a delta.
  snapshot_sent_at : Map[String, UInt64]
  mut refresh_pending : Bool
}

///|
let port_scanner_state : PortScannerState = {
  last_scan: [],
  initialized: false,
  broadcast_set: {},
  remote_ports_by_peer: {},
  remote_last_updated: {},
  snapshot_sent_at: {},
  refresh_pending: false,
}

///|
/// True when the given (protocol, port) pair is currently in the local
/// broadcast set — i.e. this node has recently scanned and advertised it.
///
/// Used by the port_forward_open handler to authorize incoming pull requests.
fn is_local_port_broadcast(protocol : String, port : Int) -> Bool {
  let key = protocol + "|" + port.to_string()
  port_scanner_state.broadcast_set.contains(key)
}

///|
/// Update the fast-lookup broadcast set from a full port list.
///
/// Called after every successful scan; the set is the authoritative "these
/// are the ports we've advertised" and is what `is_local_port_broadcast` reads.
fn update_local_broadcast_set(entries : Array[LocalPortEntry]) -> Unit {
  port_scanner_state.broadcast_set.clear()
  for entry in entries {
    let key = entry.protocol + "|" + entry.port.to_string()
    port_scanner_state.broadcast_set[key] = true
  }
}

///|
/// Parse the field-mode (`-F pcn`) output of a single `lsof` invocation.
///
/// The format is one record per process, with lines like:
/// ```
/// p1234
/// cpostgres
/// n127.0.0.1:5432
/// n[::1]:5432
/// ```
/// A `p` line starts a new process record and carries the PID. Every following
/// `c` line updates the current command name. Every `n` line describes one
/// socket bind (address:port). We keep parsing until the next `p` starts a new
/// record.
fn parse_lsof_output(raw : String, protocol : String) -> Array[LocalPortEntry] {
  let out : Array[LocalPortEntry] = []
  let mut current_command : String? = None
  for line in raw.split("\n") {
    let line = line.to_owned()
    if line.length() == 0 {
      continue
    }
    let tag = line[0]
    let value = line[1:].to_owned()
    if tag == 'p' {
      // New process record; reset command until we see it again.
      current_command = None
    } else if tag == 'c' {
      current_command = Some(value)
    } else if tag == 'n' {
      match parse_lsof_name_field(value) {
        Some((bind_addr, port)) =>
          out.push({ protocol, bind_addr, port, process_name: current_command })
        None => ()
      }
    }
  }
  out
}

///|
/// Parse one lsof `n` field into (bind_addr, port).
///
/// Handles the shapes lsof emits for listening sockets:
///   - `*:80`               → ("*", 80)
///   - `127.0.0.1:5432`     → ("127.0.0.1", 5432)
///   - `[::1]:5432`         → ("::1", 5432)
///   - `[::]:*`             → skipped (wildcard port, not a real listener)
///   - `10.0.0.1:5000->…`   → skipped (established, not listening — belt-and-suspenders)
fn parse_lsof_name_field(field : String) -> (String, Int)? {
  if field.contains("->") {
    return None
  }
  let colon = last_index_of_char(field, ':')
  guard colon is Some(idx) else { return None }
  let addr_raw = field[:idx].to_owned()
  let port_str = field[idx + 1:].to_owned()
  let port = @string.parse_int(port_str) catch { _ => return None }
  if port <= 0 || port > 65535 {
    return None
  }
  // Strip square brackets from IPv6 literals.
  let bind_addr = if addr_raw.has_prefix("[") && addr_raw.has_suffix("]") {
    addr_raw[1:addr_raw.length() - 1].to_owned()
  } else {
    addr_raw
  }
  Some((bind_addr, port))
}

///|
fn last_index_of_char(s : String, target : Char) -> Int? {
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
/// Compare two scan results, returning entries present only in one side.
///
/// `prev` and `curr` should already be sorted with `compare_local_port_entry`;
/// dedup keys are `local_port_entry_key`, so two entries with the same
/// (protocol, port, bind_addr) but different `process_name` are treated as
/// the same underlying binding (process name is best-effort and often churns).
fn diff_local_ports(
  prev : Array[LocalPortEntry],
  curr : Array[LocalPortEntry],
) -> (Array[LocalPortEntry], Array[LocalPortEntry]) {
  let prev_set : Map[String, LocalPortEntry] = {}
  for e in prev {
    prev_set[local_port_entry_key(e)] = e
  }
  let curr_set : Map[String, LocalPortEntry] = {}
  for e in curr {
    curr_set[local_port_entry_key(e)] = e
  }
  let added : Array[LocalPortEntry] = []
  let removed : Array[LocalPortEntry] = []
  for key, entry in curr_set {
    if !prev_set.contains(key) {
      added.push(entry)
    }
  }
  for key, entry in prev_set {
    if !curr_set.contains(key) {
      removed.push(entry)
    }
  }
  added.sort_by(compare_local_port_entry)
  removed.sort_by(compare_local_port_entry)
  (added, removed)
}

///|
/// Run one external command and return its stdout on exit-code 0, else None.
///
/// Errors, non-zero exits, and pipe failures all fold into `None` — a scanner
/// backend can then fall back to an alternative (e.g. netstat when lsof is
/// missing).
async fn run_scanner_command(program : String, args : Array[String]) -> String? {
  let (stdout_r, stdout_w) = @pipe.pipe() catch { _ => return None }
  let exit_code = @process.run(program, args, stdout=stdout_w) catch {
    _ => {
      stdout_w.close()
      stdout_r.close()
      return None
    }
  }
  stdout_w.close()
  let output = stdout_r.read_all().text() catch {
      _ => {
        stdout_r.close()
        return None
      }
    }
  stdout_r.close()
  if exit_code == 0 {
    Some(output)
  } else {
    None
  }
}

///|
/// Scan local listening ports.
///
/// Currently backed by `lsof` (macOS + Linux). Windows returns an empty list
/// and logs a warning on first call.
async fn scan_local_listening_ports() -> Array[LocalPortEntry] {
  let tcp_raw = run_scanner_command("lsof", [
    "-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn",
  ]).unwrap_or("")
  let udp_raw = run_scanner_command("lsof", ["-nP", "-iUDP", "-Fpcn"]).unwrap_or(
    "",
  )
  let entries : Array[LocalPortEntry] = []
  for e in parse_lsof_output(tcp_raw, "tcp") {
    entries.push(e)
  }
  for e in parse_lsof_output(udp_raw, "udp") {
    entries.push(e)
  }
  let filtered = filter_self_and_forward_ports(entries)
  filtered.sort_by(compare_local_port_entry)
  filtered
}

///|
/// Remove entries corresponding to:
///   - msgtier's own listeners (from `config.listeners`),
///   - ports already opened by our own port_forward listeners.
/// Also drops the `msgtier` process itself as belt-and-suspenders.
fn filter_self_and_forward_ports(
  entries : Array[LocalPortEntry],
) -> Array[LocalPortEntry] {
  let self_ports : Map[Int, Bool] = {}
  for listener in get_config().listeners {
    match @url.Url::parse(listener) {
      Some(url) => {
        let port_str = url.get_port()
        if port_str != "" {
          let p = @string.parse_int(port_str) catch { _ => -1 }
          if p > 0 {
            self_ports[p] = true
          }
        }
      }
      None => ()
    }
  }
  for _key, server in port_forward_registry_state.tcp_forward_servers {
    self_ports[server.addr.port()] = true
  }
  for _key, runtime in port_forward_registry_state.udp_forward_runtimes {
    self_ports[runtime.server.addr.port()] = true
  }
  let out : Array[LocalPortEntry] = []
  for e in entries {
    if self_ports.contains(e.port) {
      continue
    }
    if e.process_name is Some(name) && name == "msgtier" {
      continue
    }
    out.push(e)
  }
  out
}

///|
/// Replace this peer's snapshot with the given entries.
fn set_remote_ports_for_peer(
  peer_id : String,
  entries : Array[LocalPortEntry],
) -> Unit {
  entries.sort_by(compare_local_port_entry)
  port_scanner_state.remote_ports_by_peer[peer_id] = entries
  port_scanner_state.remote_last_updated[peer_id] = @env.now()
}

///|
/// Apply an add/remove delta to this peer's current snapshot.
///
/// Missing peer entry (never got a snapshot) starts an empty list — a stray
/// delta simply establishes the "added" portion.
fn apply_remote_ports_delta(
  peer_id : String,
  added : Array[LocalPortEntry],
  removed : Array[LocalPortEntry],
) -> Unit {
  let prev = port_scanner_state.remote_ports_by_peer.get(peer_id).unwrap_or([])
  let removed_keys : Map[String, Bool] = {}
  for e in removed {
    removed_keys[local_port_entry_key(e)] = true
  }
  let merged_keys : Map[String, LocalPortEntry] = {}
  for e in prev {
    let key = local_port_entry_key(e)
    if !removed_keys.contains(key) {
      merged_keys[key] = e
    }
  }
  for e in added {
    merged_keys[local_port_entry_key(e)] = e
  }
  let out : Array[LocalPortEntry] = []
  for _key, entry in merged_keys {
    out.push(entry)
  }
  out.sort_by(compare_local_port_entry)
  port_scanner_state.remote_ports_by_peer[peer_id] = out
  port_scanner_state.remote_last_updated[peer_id] = @env.now()
}

///|
/// Handler for `port_scan_snapshot` — full replacement.
fn handle_port_scan_snapshot_message(ctx : MessageContext) -> Unit {
  let msg = ctx.msg
  if check_and_mark_processed(msg.id, msg.timestamp) {
    return
  }
  let ports_value = port_forward_array_field(msg.body, "ports")
  let entries = decode_local_port_entries(ports_value)
  set_remote_ports_for_peer(msg.source_id, entries)
  log_debug(
    "port_scan snapshot from=\{msg.source_id} count=\{entries.length()}",
  )
}

///|
/// Handler for `port_scan_delta` — incremental update.
fn handle_port_scan_delta_message(ctx : MessageContext) -> Unit {
  let msg = ctx.msg
  if check_and_mark_processed(msg.id, msg.timestamp) {
    return
  }
  let added = decode_local_port_entries(
    port_forward_array_field(msg.body, "added"),
  )
  let removed = decode_local_port_entries(
    port_forward_array_field(msg.body, "removed"),
  )
  apply_remote_ports_delta(msg.source_id, added, removed)
  log_debug(
    "port_scan delta from=\{msg.source_id} added=\{added.length()} removed=\{removed.length()}",
  )
}

///|
/// Broadcast a scan snapshot or delta to all currently-known peers.
///
/// - `snapshot` overrides any diff: every peer receives the full ports list.
///   Used by the initial scan and periodically for new peers that appeared since
///   the last poll.
/// - Otherwise, a delta is sent to every peer except those we've never sent to
///   before, who receive a snapshot as their first message.
async fn broadcast_scan_result(
  entries : Array[LocalPortEntry],
  added : Array[LocalPortEntry],
  removed : Array[LocalPortEntry],
  force_snapshot : Bool,
) -> Unit {
  let now = @env.now()
  let peers = get_global_peer_manager().get_all_peers()
  let self_id = get_config().id
  for peer in peers {
    if peer.id == self_id {
      continue
    }
    let never_sent = !port_scanner_state.snapshot_sent_at.contains(peer.id)
    if force_snapshot || never_sent {
      ignore(
        send_port_forward_message_via(
          peer.id,
          "port_scan_snapshot",
          make_port_scan_snapshot_body(entries),
          None,
        ),
      )
      port_scanner_state.snapshot_sent_at[peer.id] = now
    } else if added.length() > 0 || removed.length() > 0 {
      ignore(
        send_port_forward_message_via(
          peer.id,
          "port_scan_delta",
          make_port_scan_delta_body(added, removed),
          None,
        ),
      )
    }
  }
}

///|
/// Perform one scan+diff+broadcast cycle.
///
/// Returns the fresh entries so callers (e.g. the HTTP refresh endpoint) can
/// echo the count.
async fn perform_port_scan_cycle(
  force_snapshot : Bool,
) -> Array[LocalPortEntry] {
  let curr = scan_local_listening_ports()
  let (added, removed) = diff_local_ports(port_scanner_state.last_scan, curr)
  port_scanner_state.last_scan = curr
  update_local_broadcast_set(curr)
  let should_broadcast = force_snapshot ||
    added.length() > 0 ||
    removed.length() > 0
  if should_broadcast {
    broadcast_scan_result(curr, added, removed, force_snapshot)
  } else {
    // Snapshot brand-new peers even without local changes.
    let peers = get_global_peer_manager().get_all_peers()
    let self_id = get_config().id
    let now = @env.now()
    for peer in peers {
      if peer.id == self_id {
        continue
      }
      if !port_scanner_state.snapshot_sent_at.contains(peer.id) {
        ignore(
          send_port_forward_message_via(
            peer.id,
            "port_scan_snapshot",
            make_port_scan_snapshot_body(curr),
            None,
          ),
        )
        port_scanner_state.snapshot_sent_at[peer.id] = now
      }
    }
  }
  curr
}

///|
/// Request an out-of-band scan+broadcast.

///|
/// Start the port scanner background task.
///
/// - First scan runs immediately, then every 30 s.
/// - `request_port_scan_refresh` short-circuits the wait for the next tick.
fn init_port_scanner(root : @async.TaskGroup[Unit]) -> Unit {
  if port_scanner_state.initialized {
    return
  }
  port_scanner_state.initialized = true
  root.spawn_bg(async fn() {
    // Initial scan produces the baseline broadcast set.
    ignore(perform_port_scan_cycle(true))
    for ;; {
      let start = @env.now()
      let interval_ms : UInt64 = 30000UL
      while @env.now() - start < interval_ms &&
            !port_scanner_state.refresh_pending {
        @async.sleep(500)
      }
      let forced = port_scanner_state.refresh_pending
      port_scanner_state.refresh_pending = false
      ignore(perform_port_scan_cycle(forced))
    }
  })
}
