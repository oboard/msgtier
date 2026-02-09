///|
pub fn can_direct_connect(peer_id : String) -> Bool {
  let conns = get_global_connection_manager().get_peer_connections(peer_id)
  for conn in conns {
    // If we have an active connection with relay=1, it is direct.
    // Also check if remote_addr is valid (not "routed")
    if conn.relay == 1 && conn.remote_addr != "routed" {
      return true
    }
  }
  false
}

///|
let message_timeout_ms : UInt64 = 30000

///|
pub async fn relay_message(
  transport : &Transport,
  my_id : String,
  msg : Message,
  target_peer_id : String,
) -> Unit noraise {
  // Check for timeout
  let now = @env.now()
  if now > msg.timestamp && now - msg.timestamp > message_timeout_ms {
    log_warn(
      "Message \{msg.id} timed out during relay (age: \{now - msg.timestamp}ms), dropped",
    )
    return
  }

  // Check if this node has already processed this message (prevent loops using DFS path tracking)
  let already_visited = msg.visited.any(peer_id => peer_id == my_id)
  if !already_visited {
    let updated_visited = msg.visited
    updated_visited.push(my_id)
    let relay_msg = Message::{
      ..msg,
      relay: msg.relay + 1,
      visited: updated_visited,
    }

    // Use routing table to forward
    let mut forwarded = false

    // 1. Direct connection check
    let target_conns = get_global_connection_manager().get_peer_connections(
      target_peer_id,
    )
    if !target_conns.is_empty() {
      for conn in target_conns {
        ignore(send_message(transport, conn.remote_addr, relay_msg))
      }
      forwarded = true
      let path_str = relay_msg.visited.join(" -> ")
      log_debug("Forwarded to \{target_peer_id} directly, path: \{path_str}")
    }

    // 2. Routing table check
    if !forwarded {
      match get_global_peer_manager().get_route(target_peer_id) {
        Some(route) => {
          let next_hop = route.next_hop
          let next_hop_conns = get_global_connection_manager().get_peer_connections(
            next_hop,
          )
          if !next_hop_conns.is_empty() {
            let next_hop_addr = next_hop_conns[0].remote_addr
            ignore(send_message(transport, next_hop_addr, relay_msg))
            forwarded = true
            let path_str = relay_msg.visited.join(" -> ")
            log_debug(
              "Forwarded to \{target_peer_id} via \{next_hop}, path: \{path_str}",
            )
          }
        }
        None => ()
      }
    }
    if !forwarded {
      log_warn("Failed to route message to \{target_peer_id}: no route found")
    }
  }
}
