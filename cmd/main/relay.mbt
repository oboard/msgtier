///|
pub fn can_direct_connect(peer_id : String) -> Bool {
  let conns = get_global_connection_manager().get_peer_connections(peer_id)
  if !conns.any(fn(conn) { conn.relay == 1 }) {
    return false
  }
  match get_global_peer_manager().get_peer(peer_id) {
    Some(peer) =>
      for addr in peer.addresses {
        if addr != "routed" && !addr.is_empty() {
          return true
        }
      }
    None => ()
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
  allow_queueing? : Bool = false,
) -> Bool noraise {
  // Check for timeout
  let now = @env.now()
  let timeout = msg.timeout_ms.unwrap_or(message_timeout_ms)
  if now > msg.timestamp && now - msg.timestamp > timeout {
    log_warn(
      "Message \{msg.id} timed out during relay (age: \{now - msg.timestamp}ms), dropped",
    )
    return false
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
      target_id: Some(target_peer_id),
    }

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

    // 2. Routing table check
    if !forwarded {
      match get_global_peer_manager().get_route(target_peer_id) {
        Some(route) => {
          let next_hop = route.next_hop
          let next_hop_conns = get_global_connection_manager().get_peer_connections(
            next_hop,
          )

          if next_hop_conns.is_empty() {
            log_debug(
              "Route to \{target_peer_id} via \{next_hop} exists, but next hop is not connected",
            )
          } else {
            match pick_peer_address(next_hop, transport.protocol()) {
              Some(addr) => {
                let next_hop_addr = if addr.contains("://") {
                  addr
                } else {
                  transport.protocol() + "://" + addr
                }
                if !next_hop_addr.is_empty() && next_hop_addr != "routed" {
                  ignore(send_message(transport, next_hop_addr, relay_msg))
                  forwarded = true
                  let path_str = relay_msg.visited.join(" -> ")
                  log_debug(
                    "Forwarded to \{target_peer_id} via \{next_hop}, path: \{path_str}",
                  )
                }
              }
              None => {
                log_debug(
                  "Cannot relay to \{target_peer_id} via \{next_hop}: no matching transport \{transport.protocol()}",
                )
                if allow_queueing {
                  add_pending_message(relay_msg)
                  forwarded = true
                  log_debug(
                    "Queued relay message \{msg.id} for cross-protocol delivery via \{next_hop}",
                  )
                }
              }
            }
          }
        }
        None => {
          // No route found in routing table.
          // Try to find a public node to forward to (Foreign Network Relay)
          let all_conns = get_global_connection_manager().get_all_connections()
          let mut public_relay_found = false
          let mut public_relay_other_protocol_found = false
          for conn in all_conns {
            // Skip sender and visited
            let is_visited = msg.visited.any(fn(pid) { pid == conn.peer_id })
            if conn.peer_id == msg.source_id || is_visited {
              continue
            }

            // Check if public (heuristic: remote address is not private/loopback)
            match pick_peer_address(conn.peer_id, transport.protocol()) {
              Some(relay_addr) => {
                let host = extract_host(relay_addr)
                if !is_private(host) && !is_loopback(host) {
                  let relay_addr = if relay_addr.contains("://") {
                    relay_addr
                  } else {
                    transport.protocol() + "://" + relay_addr
                  }
                  ignore(send_message(transport, relay_addr, relay_msg))
                  log_debug(
                    "Forwarded to public relay \{conn.peer_id} (fallback for \{target_peer_id})",
                  )
                  public_relay_found = true
                  forwarded = true
                  break
                }
              }
              None =>
                match get_global_peer_manager().get_peer(conn.peer_id) {
                  Some(peer) =>
                    for addr in peer.addresses {
                      let mut parsed : Address? = None
                      try {
                        parsed = Some(Address::parse(addr))
                      } catch {
                        _ => ()
                      }
                      match parsed {
                        Some(parsed_addr) =>
                          if parsed_addr.protocol.to_string() !=
                            transport.protocol() {
                            public_relay_other_protocol_found = true
                          }
                        None => ()
                      }
                    }
                  None => ()
                }
            }
          }
          if !public_relay_found {
            if allow_queueing && public_relay_other_protocol_found {
              add_pending_message(relay_msg)
              forwarded = true
              log_debug(
                "Queued relay message \{msg.id} for foreign relay via other protocol",
              )
            } else {
              log_warn(
                "No route and no public relay found for \{target_peer_id}",
              )
            }
          }
        }
      }
    }
    forwarded
  } else {
    false
  }
}
