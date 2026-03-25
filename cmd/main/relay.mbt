///|
struct RelayState {
  default_timeout_ms : UInt
}

///|
let relay_state : RelayState = { default_timeout_ms: 30000 }

///|
fn prepare_relay_message(
  my_id : String,
  msg : Message,
  target_peer_id : String,
) -> Message? {
  let now = @env.now()
  let timeout = msg.timeout_ms.unwrap_or(relay_state.default_timeout_ms)
  let timeout_u64 = timeout.to_uint64()
  if now > msg.timestamp && now - msg.timestamp > timeout_u64 {
    log_warn(
      "Message \{msg.id} timed out during relay (age: \{now - msg.timestamp}ms), dropped",
    )
    return None
  }
  if msg.visited.any(peer_id => peer_id == my_id) {
    return None
  }
  let updated_visited = msg.visited
  updated_visited.push(my_id)
  Some(Message::{
    ..msg,
    relay: msg.relay + 1,
    visited: updated_visited,
    target_id: Some(target_peer_id),
  })
}

///|
fn resolve_relay_target_addr(
  source_id : String,
  visited : Array[String],
  target_peer_id : String,
  protocol : String,
) -> (String, String)? {
  if get_global_peer_manager().get_route(target_peer_id) is Some(route) {
    for addr in message_route_candidates(route.next_hop, protocol) {
      return Some((route.next_hop, addr))
    }
  }
  for conn in get_global_connection_manager().get_all_connections() {
    let is_visited = visited.any(fn(peer_id) { peer_id == conn.peer_id })
    if conn.peer_id == source_id || is_visited {
      continue
    }
    for relay_addr in message_route_candidates(conn.peer_id, protocol) {
      let host = extract_host(relay_addr)
      if !is_private(host) && !is_loopback(host) {
        return Some((conn.peer_id, relay_addr))
      }
    }
  }
  None
}

///|
async fn relay_message_with_route(
  transport : &Transport,
  my_id : String,
  msg : Message,
  target_peer_id : String,
) -> (Bool, String?) noraise {
  guard prepare_relay_message(my_id, msg, target_peer_id) is Some(relay_msg) else {
    return (false, None)
  }
  guard resolve_relay_target_addr(
      msg.source_id,
      relay_msg.visited,
      target_peer_id,
      transport.protocol(),
    )
    is Some((next_hop, relay_addr)) else {
    return (false, None)
  }
  if send_message(transport, relay_addr, relay_msg) {
    let path_str = relay_msg.visited.join(" -> ")
    log_debug(
      "Forwarded to \{target_peer_id} via \{next_hop}, path: \{path_str}",
    )
    (true, Some(relay_addr))
  } else {
    (false, None)
  }
}

///|
pub async fn relay_message(
  transport : &Transport,
  my_id : String,
  msg : Message,
  target_peer_id : String,
  allow_queueing? : Bool = false,
) -> Bool noraise {
  if prepare_relay_message(my_id, msg, target_peer_id) is Some(relay_msg) {

    // Use routing table to forward
    let mut forwarded = false

    // 1. Direct connection check
    let target_conns = get_global_connection_manager().get_peer_connections(
      target_peer_id,
    )
    let mut direct_sent = false
    if !target_conns.is_empty() {
      match pick_peer_address(target_peer_id, transport.protocol()) {
        Some(addr) => {
          let target_addr = if addr.contains("://") {
            addr
          } else {
            transport.protocol() + "://" + addr
          }
          if !target_addr.is_empty() && target_addr != "routed" {
            let ok = send_message(transport, target_addr, relay_msg)
            if ok {
              direct_sent = true
            }
          }
        }
        None => ()
      }
      if direct_sent {
        forwarded = true
        let path_str = relay_msg.visited.join(" -> ")
        log_debug("Forwarded to \{target_peer_id} directly, path: \{path_str}")
      } else if allow_queueing {
        add_pending_message(relay_msg)
        forwarded = true
        log_debug(
          "Queued relay message \{msg.id} for direct delivery via other protocol",
        )
      }
    }

    // 2. LAN direct address check
    if !forwarded {
      match pick_peer_lan_address(target_peer_id, transport.protocol()) {
        Some(addr) => {
          let target_addr = if addr.contains("://") {
            addr
          } else {
            transport.protocol() + "://" + addr
          }
          if !target_addr.is_empty() && target_addr != "routed" {
            let ok = send_message(transport, target_addr, relay_msg)
            if ok {
              forwarded = true
              let path_str = relay_msg.visited.join(" -> ")
              log_debug(
                "Forwarded to \{target_peer_id} via LAN, path: \{path_str}",
              )
            }
          }
        }
        None => ()
      }
    }

    // 3. Routing table check
    if !forwarded {
      if relay_message_with_route(transport, my_id, msg, target_peer_id)
        is (true, Some(_)) {
        forwarded = true
      } else if allow_queueing {
        add_pending_message(relay_msg)
        forwarded = true
        log_debug("Queued relay message \{msg.id} for relay delivery")
      } else {
        log_warn("No relay route found for \{target_peer_id}")
      }
    }
    forwarded
  } else {
    false
  }
}
