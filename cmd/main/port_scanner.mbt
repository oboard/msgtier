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
/// On Linux we prefer `/proc/net/{tcp,tcp6,udp,udp6}` because it lists sockets
/// system-wide regardless of the socket owner's uid — `lsof` on Linux walks
/// `/proc/<pid>/fd/` and can only see file descriptors belonging to the same
/// uid, so a non-root msgtier would otherwise be blind to every other user's
/// listeners. The `/proc/net/*` files are world-readable but do not carry a
/// process name, so `process_name` becomes `None` on that path.
///
/// macOS (and any other platform where `/proc/net/tcp` is missing) falls back
/// to `lsof`. Windows still returns an empty list.
async fn scan_local_listening_ports() -> Array[LocalPortEntry] {
  let entries = match scan_via_proc_net() {
    Some(entries) => entries
    None => scan_via_lsof()
  }
  let filtered = filter_self_and_forward_ports(entries)
  filtered.sort_by(compare_local_port_entry)
  filtered
}

///|
async fn scan_via_lsof() -> Array[LocalPortEntry] {
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
  entries
}

///|
/// Read `/proc/net/{tcp,tcp6,udp,udp6}` when present.
///
/// Returns `None` on any platform where `/proc/net/tcp` is not readable — the
/// caller then falls back to `lsof`. When present, all four files are read and
/// the union of their listening sockets is returned.
async fn scan_via_proc_net() -> Array[LocalPortEntry]? {
  if !(@fs.exists("/proc/net/tcp") catch { _ => false }) {
    return None
  }
  let entries : Array[LocalPortEntry] = []
  for
    spec in [
      ("/proc/net/tcp", "tcp", false, true),
      ("/proc/net/tcp6", "tcp", true, true),
      ("/proc/net/udp", "udp", false, false),
      ("/proc/net/udp6", "udp", true, false),
    ] {
    let (path, protocol, is_v6, listen_only) = spec
    let raw = @fs.read_file(path).text() catch { _ => continue }
    for e in parse_proc_net(raw, protocol, is_v6~, listen_only~) {
      entries.push(e)
    }
  }
  Some(entries)
}

///|
/// Parse the body of a `/proc/net/{tcp,udp}[6]` file into port entries.
///
/// Format (relevant columns only):
/// ```
///   sl  local_address rem_address st ...
///    0: 0100007F:1F90 00000000:0000 0A ...
/// ```
/// - `local_address` is `<hex-addr>:<hex-port>`
/// - `st == "0A"` is TCP LISTEN. UDP has no LISTEN state, so `listen_only=false`
///   keeps every bound socket regardless of `st`.
///
/// Malformed rows fold silently to nothing — `/proc/net/*` layout is stable
/// but skipping a bad row is cheaper than raising on a kernel edge case.
fn parse_proc_net(
  raw : String,
  protocol : String,
  is_v6~ : Bool,
  listen_only~ : Bool,
) -> Array[LocalPortEntry] {
  let out : Array[LocalPortEntry] = []
  let mut first_line = true
  for line in raw.split("\n") {
    let line = line.to_owned()
    if first_line {
      // Header row: `  sl  local_address rem_address st ...`
      first_line = false
      continue
    }
    if line.trim() == "" {
      continue
    }
    match parse_proc_net_line(line, is_v6~, listen_only~) {
      Some((bind_addr, port)) =>
        out.push({ protocol, bind_addr, port, process_name: None })
      None => ()
    }
  }
  out
}

///|
/// Parse one non-header line from `/proc/net/{tcp,udp}[6]`.
///
/// Splits on whitespace, decodes column 1 (`local_address = HEXADDR:HEXPORT`)
/// and — when `listen_only` — checks column 3 (`st`) is TCP LISTEN (`0A`).
fn parse_proc_net_line(
  line : String,
  is_v6~ : Bool,
  listen_only~ : Bool,
) -> (String, Int)? {
  let cols : Array[String] = []
  let mut cur = StringBuilder::new()
  let space = ' '.to_int()
  let tab = '\t'.to_int()
  for i = 0; i < line.length(); i = i + 1 {
    let ch = line[i].to_int()
    if ch == space || ch == tab {
      let piece = cur.to_string()
      if piece != "" {
        cols.push(piece)
      }
      cur = StringBuilder::new()
    } else {
      cur.write_char(ch.unsafe_to_char())
    }
  }
  let last_piece = cur.to_string()
  if last_piece != "" {
    cols.push(last_piece)
  }
  // Column layout: [sl, local_addr, rem_addr, st, ...]
  if cols.length() < 4 {
    return None
  }
  if listen_only && cols[3] != "0A" {
    return None
  }
  let local_addr = cols[1]
  let colon = index_of_char(local_addr, ':') // exactly one ':' in this column
  guard colon is Some(idx) else { return None }
  let addr_hex = local_addr[:idx].to_owned()
  let port_hex = local_addr[idx + 1:].to_owned()
  let port = @string.parse_int(port_hex, base=16) catch { _ => return None }
  if port <= 0 || port > 65535 {
    return None
  }
  let addr = if is_v6 {
    decode_proc_net_ipv6(addr_hex)
  } else {
    decode_proc_net_ipv4(addr_hex)
  }
  guard addr is Some(bind_addr) else { return None }
  Some((bind_addr, port))
}

///|
fn index_of_char(s : String, target : Char) -> Int? {
  let target_int = target.to_int()
  for i = 0; i < s.length(); i = i + 1 {
    if s[i].to_int() == target_int {
      return Some(i)
    }
  }
  None
}

///|
/// Decode a `/proc/net/tcp` IPv4 hex address.
///
/// The 4 bytes are printed **little-endian** (`0100007F` reads back as bytes
/// `01 00 00 7F` which on a little-endian host means network-order
/// `7F 00 00 01` = `127.0.0.1`).
fn decode_proc_net_ipv4(hex : String) -> String? {
  if hex.length() != 8 {
    return None
  }
  let bytes : Array[Int] = []
  for i = 0; i < 4; i = i + 1 {
    let byte = @string.parse_int(hex[i * 2:i * 2 + 2].to_owned(), base=16) catch {
      _ => return None
    }
    bytes.push(byte)
  }
  // File is little-endian; reverse for dotted-decimal (network order).
  Some("\{bytes[3]}.\{bytes[2]}.\{bytes[1]}.\{bytes[0]}")
}

///|
/// Decode a `/proc/net/tcp6` IPv6 hex address.
///
/// The 16 bytes are printed as four 32-bit words, each word in host
/// (little-endian) byte order. So `00000000000000000000000001000000` decodes
/// to `::1`. Also detects v4-mapped addresses `::ffff:a.b.c.d` and prints them
/// as dotted-decimal for parity with `lsof` output.
fn decode_proc_net_ipv6(hex : String) -> String? {
  if hex.length() != 32 {
    return None
  }
  // Decode into 16 network-order bytes.
  let bytes : Array[Int] = []
  for w = 0; w < 4; w = w + 1 {
    let word_hex = hex[w * 8:w * 8 + 8].to_owned()
    let word_bytes : Array[Int] = []
    for i = 0; i < 4; i = i + 1 {
      let b = @string.parse_int(word_hex[i * 2:i * 2 + 2].to_owned(), base=16) catch {
        _ => return None
      }
      word_bytes.push(b)
    }
    // Little-endian word → reverse to get network order for this word.
    for i = 3; i >= 0; i = i - 1 {
      bytes.push(word_bytes[i])
    }
  }
  // v4-mapped: ::ffff:a.b.c.d — first 10 bytes 0, next 2 bytes 0xff.
  let mut is_v4_mapped = true
  for i = 0; i < 10; i = i + 1 {
    if bytes[i] != 0 {
      is_v4_mapped = false
      break
    }
  }
  if is_v4_mapped && bytes[10] == 0xff && bytes[11] == 0xff {
    return Some("\{bytes[12]}.\{bytes[13]}.\{bytes[14]}.\{bytes[15]}")
  }
  // Assemble 8 groups of 16-bit hex, then apply `::` compression.
  let groups : Array[String] = []
  for i = 0; i < 8; i = i + 1 {
    let hi = bytes[i * 2]
    let lo = bytes[i * 2 + 1]
    let val = hi * 256 + lo
    groups.push(int_to_hex_lowercase(val))
  }
  Some(compress_ipv6_groups(groups))
}

///|
/// Format an int (0..=0xffff) as lowercase hex, no leading zeros. `0` → `"0"`.
fn int_to_hex_lowercase(v : Int) -> String {
  if v == 0 {
    return "0"
  }
  let digits = [
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
  ]
  let sb = StringBuilder::new()
  let buf : Array[Char] = []
  let mut n = v
  while n > 0 {
    buf.push(digits[n % 16])
    n = n / 16
  }
  for i = buf.length() - 1; i >= 0; i = i - 1 {
    sb.write_char(buf[i])
  }
  sb.to_string()
}

///|
/// Compress the longest run of consecutive zero groups with `::` per RFC 5952.
///
/// Runs of length 1 are still compressed to `::` when they are the *only* zero
/// span — matches the widely-used stringify behavior (`0:0:0:0:0:0:0:0` →
/// `::`, `1:0:0:0:0:0:0:1` → `1::1`, `1:0:2:3:4:5:6:7` → `1:0:2:3:4:5:6:7`).
fn compress_ipv6_groups(groups : Array[String]) -> String {
  // Find the longest run of "0" groups.
  let mut best_start = -1
  let mut best_len = 0
  let mut cur_start = -1
  let mut cur_len = 0
  for i = 0; i < groups.length(); i = i + 1 {
    if groups[i] == "0" {
      if cur_len == 0 {
        cur_start = i
      }
      cur_len = cur_len + 1
      if cur_len > best_len {
        best_len = cur_len
        best_start = cur_start
      }
    } else {
      cur_len = 0
    }
  }
  if best_len < 2 {
    return groups.join(":")
  }
  let sb = StringBuilder::new()
  for i = 0; i < best_start; i = i + 1 {
    if i > 0 {
      sb.write_char(':')
    }
    sb.write_string(groups[i])
  }
  sb.write_string("::")
  let tail_start = best_start + best_len
  for i = tail_start; i < groups.length(); i = i + 1 {
    if i > tail_start {
      sb.write_char(':')
    }
    sb.write_string(groups[i])
  }
  sb.to_string()
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
/// Send a full snapshot to every peer we haven't sent to yet.
///
/// This is what covers the "peer connected mid-cycle" case: the 30 s scan tick
/// fires only every 30 s, but peer handshakes complete on their own schedule
/// (typically within a few seconds of startup). Without this, a peer that
/// connects at T = 5 s wouldn't see any snapshot until T = 30 s. Calling this
/// on the 500 ms wait loop closes that window down to ~500 ms.
///
/// No-op for peers that have already received any snapshot.
async fn snapshot_new_peers() -> Unit {
  let peers = get_global_peer_manager().get_all_peers()
  let self_id = get_config().id
  let now = @env.now()
  let curr = port_scanner_state.last_scan
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
    snapshot_new_peers()
  }
  curr
}

///|
/// Request an out-of-band scan+broadcast.

///|
/// Start the port scanner background task.
///
/// - First scan runs immediately, then every 30 s.
/// - Between ticks, every 500 ms we check for peers that connected since the
///   last cycle and send them a first snapshot — otherwise a peer that
///   handshakes right after the initial scan waits a full 30 s to learn our
///   ports.
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
        snapshot_new_peers()
        @async.sleep(500)
      }
      let forced = port_scanner_state.refresh_pending
      port_scanner_state.refresh_pending = false
      ignore(perform_port_scan_cycle(forced))
    }
  })
}
