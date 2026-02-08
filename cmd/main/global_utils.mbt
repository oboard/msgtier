///|

///|
/// Global state for the peer manager using new architecture
let global_peer_manager : Ref[PeerManager] = Ref::new(PeerManager::new())

///|
enum LogLevel {
  Debug
  Info
  Warn
  Error
} derive(Show, Eq, ToJson, FromJson)

///|
fn log_level_value(level : LogLevel) -> Int {
  match level {
    Debug => 0
    Info => 1
    Warn => 2
    Error => 3
  }
}

///|
fn log_with_level(level : LogLevel, msg : String) -> Unit {
  if log_level_value(level) >= log_level_value(get_config().log.unwrap_or(Info)) {
    println(msg)
  }
}

///|
fn log_debug(msg : &Show) -> Unit {
  log_with_level(Debug, msg.to_string())
}

///|
fn log_info(msg : &Show) -> Unit {
  log_with_level(Info, msg.to_string())
}

///|
fn log_warn(msg : &Show) -> Unit {
  log_with_level(Warn, msg.to_string())
}

///|
fn log_error(msg : &Show) -> Unit {
  log_with_level(Error, msg.to_string())
}

///|
/// Global list of all known peer addresses (configured + discovered)
/// Used for active connection attempts
let global_known_peers : Ref[Map[String, UInt64]] = Ref::new({})

///|
/// Add a peer address to the known peers list
fn add_known_peer(peer_addr : String) -> Unit {
  if is_bind_all_address(peer_addr) {
    return
  }
  if @url.Url::parse(peer_addr) is Some(url) {
    if url.hostname() == "0.0.0.0" {
      return
    }
    // Remove trailing slash from path if it is just root
    if url.pathname() == "/" {
      url.set_pathname("")
    }
    let peer_addr = url.to_string()
    let peers = global_known_peers.val
    if !peers.contains(peer_addr) {
      peers[peer_addr] = @env.now() // Track when we first learned about this peer
    }
  }
}

///|
fn is_bind_all_address(addr : String) -> Bool {
  match @url.Url::parse(addr) {
    Some(url) => url.hostname() == "0.0.0.0"
    None => addr.contains("0.0.0.0")
  }
}

///|
/// Get all known peer addresses
fn get_all_known_peers() -> Array[String] {
  global_known_peers.val.keys().to_array()
}

///|
/// Global mapping of peer_id -> last time we received/processed hello from them
/// Used to debounce re-broadcasting of hello messages
let global_hello_times : Ref[Map[String, UInt64]] = Ref::new({})

///|
/// Check if we should re-broadcast hello for this peer (debounce check)
/// Only re-broadcast once per 5 second period
fn should_rebroadcast_hello(peer_id : String) -> Bool {
  let times = global_hello_times.val
  let now = @env.now()
  match times.get(peer_id) {
    Some(last_time) => now - last_time > 5000UL // 5 seconds
    None => true // Never seen this peer before, always process
  }
}

///|
/// Record that we processed a hello from this peer
fn record_hello_time(peer_id : String) -> Unit {
  let times = global_hello_times.val
  times[peer_id] = @env.now()
}

///|
/// Global mapping of discovered_address -> (peer_id, relay_via_peer_id)
/// Tracks the relay path for discovered peers:
/// - discovered_address: the address we learned about (e.g., "192.168.1.5:6668")
/// - peer_id: the peer at that address
/// - relay_via_peer_id: which peer told us about this address (relay through this peer)
let global_relay_paths : Ref[Map[String, (String, String)]] = Ref::new({})

///|
/// Record a relay path: when peer B advertises peer C's address, relay through B to reach C
fn set_relay_path(
  discovered_address : String,
  peer_id : String,
  relay_via_peer_id : String,
) -> Unit {
  let paths = global_relay_paths.val
  // Prevent unbounded growth - simple cache eviction
  if paths.length() > 1000 {
    paths.clear()
  }
  paths[discovered_address] = (peer_id, relay_via_peer_id)
  // println(
  //   "DEBUG: Set relay path - reach \{peer_id} at \{discovered_address} via relay through \{relay_via_peer_id}",
  // )
}

///|
/// Get the relay path for a discovered address
fn get_relay_path(address : String) -> (String, String)? {
  let paths = global_relay_paths.val
  paths.get(address)
}

///|
/// Update global peer manager state
fn update_global_peer_manager(fn_update : (PeerManager) -> PeerManager) -> Unit {
  let current = global_peer_manager.val
  let updated = fn_update(current)
  global_peer_manager.val = updated
}

///|
/// Get current global peer manager
fn get_global_peer_manager() -> PeerManager {
  global_peer_manager.val
}

///|
/// Global state for the connection manager
let global_connection_manager : Ref[ConnectionManager] = Ref::new(
  ConnectionManager::new(),
)

///|
/// Update global connection manager state
fn update_global_connection_manager(
  fn_update : (ConnectionManager) -> ConnectionManager,
) -> Unit {
  let current = global_connection_manager.val
  let updated = fn_update(current)
  global_connection_manager.val = updated
}

///|
/// Get current global connection manager
fn get_global_connection_manager() -> ConnectionManager {
  global_connection_manager.val
}
