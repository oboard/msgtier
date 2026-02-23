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
fn add_known_peers(peer_addrs : Array[String]) -> Unit {
  for addr in peer_addrs {
    add_known_peer(addr)
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
fn pick_peer_address(peer_id : String, protocol : String) -> String? {
  // Try to find best address from connection stats first
  let conns = get_global_connection_manager().get_peer_connections(peer_id)
  let combined_stats : Map[String, AddressStats] = {}
  
  for conn in conns {
    if conn.relay == 1 {
      match conn.get_best_address(protocol) {
        Some(addr) => return Some(addr)
        None => ()
      }
      // Collect stats for fallback logic
      for k, v in conn.address_stats {
        combined_stats[k] = v
      }
    }
  }

  match get_global_peer_manager().get_peer(peer_id) {
    Some(peer) => {
      let known_peers = get_all_known_peers()
      
      // Categorize candidates
      let good_candidates : Array[String] = [] // Have received pongs
      let neutral_candidates : Array[String] = [] // No stats yet
      let bad_candidates : Array[String] = [] // Sent > 3 pings, 0 pongs
      
      for addr_str in peer.addresses {
        if addr_str.is_empty() || is_bind_all_address(addr_str) {
          continue
        }
        
        let mut parsed : Address? = None
        try {
          parsed = Some(Address::parse(addr_str))
        } catch {
          _ => ()
        }
        
        match parsed {
          Some(addr) =>
            if addr.protocol.to_string() == protocol {
              // Normalize address string to match stats keys
              // Stats keys are usually full URLs
              let full_url = if addr_str.contains("://") {
                 addr_str
              } else {
                 protocol + "://" + addr_str
              }
              
              match combined_stats.get(full_url) {
                Some(stats) => {
                  if stats.packets_received > 0 {
                    good_candidates.push(addr_str)
                  } else if stats.packets_sent > 3 {
                    bad_candidates.push(addr_str)
                  } else {
                    neutral_candidates.push(addr_str)
                  }
                }
                None => {
                  neutral_candidates.push(addr_str)
                }
              }
            }
          None => ()
        }
      }
      
      // Select best candidate based on priority
      if good_candidates.length() > 0 {
        // Sort by quality: known > low loss > low latency
        good_candidates.sort_by(fn(a, b) {
           let known_a = known_peers.contains(a)
           let known_b = known_peers.contains(b)
           if known_a && !known_b { return -1 }
           if !known_a && known_b { return 1 }
           
           // Get stats
           let url_a = if a.contains("://") { a } else { protocol + "://" + a }
           let url_b = if b.contains("://") { b } else { protocol + "://" + b }
           
           let stats_a = combined_stats.get(url_a)
           let stats_b = combined_stats.get(url_b)
           
           match (stats_a, stats_b) {
              (Some(sa), Some(sb)) => {
                 // Calculate loss rate: (sent - received) / sent
                 // We want lower loss rate.
                 
                 let loss_a = if sa.packets_sent > 0 { 
                    (sa.packets_sent - sa.packets_received).to_double() / sa.packets_sent.to_double() 
                 } else { 0.0 }
                 
                 let loss_b = if sb.packets_sent > 0 { 
                    (sb.packets_sent - sb.packets_received).to_double() / sb.packets_sent.to_double() 
                 } else { 0.0 }
                 
                 if loss_a < loss_b - 0.01 { return -1 } // Significant difference
                 if loss_a > loss_b + 0.01 { return 1 }
                 
                 // If loss rate similar, check latency
                 match (sa.latency_ms, sb.latency_ms) {
                    (Some(la), Some(lb)) => la - lb
                    (Some(_), None) => -1 // Prefer known latency
                    (None, Some(_)) => 1
                    (None, None) => 0
                 }
              }
              (Some(_), None) => -1 // Prefer stats
              (None, Some(_)) => 1
              (None, None) => 0
           }
        })
        return Some(good_candidates[0])
      }
      
      if neutral_candidates.length() > 0 {
         for c in neutral_candidates {
           if known_peers.contains(c) { return Some(c) }
        }
        return Some(neutral_candidates[0])
      }
      
      // Only fallback to bad candidates if absolutely nothing else
      // But user said "only use ports that can receive ping and pong"
      // So maybe we should return None here? 
      // If we return None, we might block communication completely until a ping succeeds.
      // Given "connection completely failed" report, maybe returning None is too strict if pings are also failing.
      // But if pings are failing, data transfer will likely fail too.
      // Let's avoid bad candidates to prevent timeouts.
      
      None
    }
    None => None
  }
}

///|
fn pick_peer_lan_address(peer_id : String, protocol : String) -> String? {
  match get_global_peer_manager().get_peer(peer_id) {
    Some(peer) => {
      let known_peers = get_all_known_peers()
      let mut fallback : String? = None
      for addr_str in peer.addresses {
        if addr_str.is_empty() ||
          addr_str == "routed" ||
          is_bind_all_address(addr_str) {
          continue
        }
        let mut parsed : Address? = None
        try {
          parsed = Some(Address::parse(addr_str))
        } catch {
          _ => ()
        }
        match parsed {
          Some(addr) =>
            if addr.protocol.to_string() == protocol {
              let host = extract_host(addr_str)
              if is_private(host) || is_loopback(host) {
                if known_peers.contains(addr_str) {
                  return Some(addr_str)
                }
                match fallback {
                  Some(_) => ()
                  None => fallback = Some(addr_str)
                }
              }
            }
          None => ()
        }
      }
      fallback
    }
    None => None
  }
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
let global_hello_callback_times : Ref[Map[String, UInt64]] = Ref::new({})

///|
fn check_and_mark_hello(key : String, ttl_ms : UInt64) -> Bool {
  let now = @env.now()
  let cache = global_hello_callback_times.val
  match cache.get(key) {
    Some(last_time) =>
      if now - last_time <= ttl_ms {
        true
      } else {
        cache[key] = now
        false
      }
    None => {
      cache[key] = now
      false
    }
  }
}

///|
/// Global mapping of discovered_address -> (peer_id, relay_via_peer_id)
/// Tracks the relay path for discovered peers:
/// - discovered_address: the address we learned about (e.g., "192.168.1.5:6668")
/// - peer_id: the peer at that address
/// - relay_via_peer_id: which peer told us about this address (relay through this peer)
// let global_relay_paths : Ref[Map[String, (String, String)]] = Ref::new({})

// ///|
// /// Record a relay path: when peer B advertises peer C's address, relay through B to reach C
// fn set_relay_path(
//   discovered_address : String,
//   peer_id : String,
//   relay_via_peer_id : String,
// ) -> Unit {
//   let paths = global_relay_paths.val
//   // Prevent unbounded growth - simple cache eviction
//   if paths.length() > 1000 {
//     paths.clear()
//   }
//   paths[discovered_address] = (peer_id, relay_via_peer_id)
//   // println(
//   //   "DEBUG: Set relay path - reach \{peer_id} at \{discovered_address} via relay through \{relay_via_peer_id}",
//   // )
// }

// ///|
// /// Get the relay path for a discovered address
// fn get_relay_path(address : String) -> (String, String)? {
//   let paths = global_relay_paths.val
//   paths.get(address)
// }

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
