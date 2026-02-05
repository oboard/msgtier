///|

///|
/// Global state for the peer manager using new architecture
let global_peer_manager : Ref[PeerManager] = Ref::new(PeerManager::new())

///|
/// Global list of all known peer addresses (configured + discovered)
/// Used for active connection attempts
let global_known_peers : Ref[Map[String, UInt64]] = Ref::new({})

///|
/// Add a peer address to the known peers list
pub fn add_known_peer(peer_addr : String) -> Unit {
  if @url.Url::parse(peer_addr) is Some(url) {
    if url.hostname() == "0.0.0.0" {
      url.set_hostname("127.0.0.1")
    }
    let peer_addr = url.to_string()
    let peers = global_known_peers.val
    if !peers.contains(peer_addr) {
      peers[peer_addr] = @env.now() // Track when we first learned about this peer
    }
  }
}

///|
/// Get all known peer addresses
pub fn get_all_known_peers() -> Array[String] {
  global_known_peers.val.keys().to_array()
}

///|
/// Global mapping of peer_id -> last time we received/processed hello from them
/// Used to debounce re-broadcasting of hello messages
let global_hello_times : Ref[Map[String, UInt64]] = Ref::new({})

///|
/// Check if we should re-broadcast hello for this peer (debounce check)
/// Only re-broadcast once per 5 second period
pub fn should_rebroadcast_hello(peer_id : String) -> Bool {
  let times = global_hello_times.val
  let now = @env.now()
  match times.get(peer_id) {
    Some(last_time) => now - last_time > 5000UL // 5 seconds
    None => true // Never seen this peer before, always process
  }
}

///|
/// Record that we processed a hello from this peer
pub fn record_hello_time(peer_id : String) -> Unit {
  let times = global_hello_times.val
  times[peer_id] = @env.now()
}

///|
/// Global mapping of peer_id -> set of learned addresses for that peer
/// This implements the gossip protocol for address discovery:
/// - When a peer connects from address X claiming to be peer_id Y, we learn "Y can be reached at X"
/// - When we send welcome to a new peer, we gossip all learned addresses for all other peers
let global_learned_addresses : Ref[Map[String, Array[String]]] = Ref::new({})

///|
/// Global mapping of discovered_address -> (peer_id, relay_via_peer_id)
/// Tracks the relay path for discovered peers:
/// - discovered_address: the address we learned about (e.g., "192.168.1.5:6668")
/// - peer_id: the peer at that address
/// - relay_via_peer_id: which peer told us about this address (relay through this peer)
let global_relay_paths : Ref[Map[String, (String, String)]] = Ref::new({})

///|
/// Record a relay path: when peer B advertises peer C's address, relay through B to reach C
pub fn set_relay_path(
  discovered_address : String,
  peer_id : String,
  relay_via_peer_id : String,
) -> Unit {
  let paths = global_relay_paths.val
  paths[discovered_address] = (peer_id, relay_via_peer_id)
  // println(
  //   "DEBUG: Set relay path - reach \{peer_id} at \{discovered_address} via relay through \{relay_via_peer_id}",
  // )
}

///|
/// Get the relay path for a discovered address
pub fn get_relay_path(address : String) -> (String, String)? {
  let paths = global_relay_paths.val
  paths.get(address)
}

///|
/// Get all learned addresses across all peers (for gossip broadcast)
/// Returns Array[NetworkAddress] containing all addresses we've discovered
pub fn get_all_learned_addresses() -> Array[NetworkAddress] {
  let learned = global_learned_addresses.val
  let all_addresses : Array[NetworkAddress] = []
  for _peer_id, addrs in learned {
    for addr in addrs {
      all_addresses.push(NetworkAddress::{ address: addr })
    }
  }
  all_addresses
}

///|
/// Update global peer manager state
pub fn update_global_peer_manager(
  fn_update : (PeerManager) -> PeerManager,
) -> Unit {
  let current = global_peer_manager.val
  let updated = fn_update(current)
  global_peer_manager.val = updated
}

///|
/// Get current global peer manager
pub fn get_global_peer_manager() -> PeerManager {
  global_peer_manager.val
}

///|
/// Global state for the connection manager
let global_connection_manager : Ref[ConnectionManager] = Ref::new(
  ConnectionManager::new(),
)

///|
/// Update global connection manager state
pub fn update_global_connection_manager(
  fn_update : (ConnectionManager) -> ConnectionManager,
) -> Unit {
  let current = global_connection_manager.val
  let updated = fn_update(current)
  global_connection_manager.val = updated
}

///|
/// Get current global connection manager
pub fn get_global_connection_manager() -> ConnectionManager {
  global_connection_manager.val
}
