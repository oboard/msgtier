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
      for conn in target_conns {
        // Only send via the current transport
        if conn.protocol == transport.protocol() {
          let ok = send_message(transport, conn.remote_addr, relay_msg)
          if ok {
            direct_sent = true
          }
        }
      }
      if direct_sent {
        forwarded = true
        let path_str = relay_msg.visited.join(" -> ")
        log_debug("Forwarded to \{target_peer_id} directly, path: \{path_str}")
      } else if allow_queueing {
        // We have direct connections but not on this transport. Queue it.
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
            // Find a connection to next_hop that matches the current transport protocol
            let mut next_hop_conn_opt = None
            for conn in next_hop_conns {
              if conn.protocol == transport.protocol() {
                next_hop_conn_opt = Some(conn)
                break
              }
            }
            match next_hop_conn_opt {
              Some(conn) => {
                let next_hop_addr = conn.remote_addr
                ignore(send_message(transport, next_hop_addr, relay_msg))
                forwarded = true
                let path_str = relay_msg.visited.join(" -> ")
                log_debug(
                  "Forwarded to \{target_peer_id} via \{next_hop}, path: \{path_str}",
                )
              }
              None => {
                // If no connection matches current transport, we can't relay via this transport
                let available_protocols = StringBuilder::new()
                for c in next_hop_conns {
                  available_protocols.write_string(c.protocol + " ")
                }
                log_debug(
                  "Cannot relay to \{target_peer_id} via \{next_hop}: no matching transport \{transport.protocol()}. Available: \{available_protocols.to_string()}",
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
            let host = extract_host(conn.remote_addr)
            if !is_private(host) && !is_loopback(host) {
              // Found a public peer, try to relay to it
              if conn.protocol == transport.protocol() {
                // Check Foreign Relay BPS Limit
                let _mgr = get_global_foreign_network_manager()
                // TODO: Implement actual rate limiting logic using mgr.relay_bps_limit

                ignore(send_message(transport, conn.remote_addr, relay_msg))
                log_debug(
                  "Forwarded to public relay \{conn.peer_id} (fallback for \{target_peer_id})",
                )
                public_relay_found = true
                forwarded = true
                break
              } else {
                public_relay_other_protocol_found = true
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
