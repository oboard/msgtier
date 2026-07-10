///|
/// Heartbeat + periodic sync — the background tasks that keep peer
/// connections alive and let peers learn each other's topology.
///
/// - `handle_heartbeat` pings every known peer over each transport at a
///   fixed cadence and prunes stale connections/routes.
/// - `broadcast_sync` sends a topology snapshot to each peer, throttled to
///   at most once per second.
/// - `handle_periodic_updates` is the outer loop that fires broadcasts on a
///   coarser schedule.

///|
async fn handle_heartbeat(
  transport : &Transport,
  local_addr : String,
  from : String,
) -> Unit {
  let heartbeat_interval = 3000 // 3 seconds
  log_debug(
    "DEBUG: handle_heartbeat start protocol=\{transport.protocol()} local=\{local_addr} from=\{from}",
  )
  for ;; {
    @async.sleep(heartbeat_interval)
    let current_time = @env.now()
    let all_peers = get_global_peer_manager().get_all_peers()
    let mut needs_broadcast = false
    log_debug(
      "DEBUG: heartbeat tick protocol=\{transport.protocol()} peers=\{all_peers.length()}",
    )
    for peer in all_peers {
      let peer_id = peer.id
      let peer_conns = get_global_connection_manager().get_peer_connections(
        peer_id,
      )
      if peer_conns.is_empty() {
        // Try to ping via relay if route exists
        match get_global_peer_manager().get_route(peer_id) {
          Some(route) => {
            log_debug(
              "DEBUG: heartbeat ping via relay to=\{peer_id} next_hop=\{route.next_hop}",
            )
            let ping_msg = Message(
              kind="ping",
              source_id=from,
              source_addr=local_addr,
              version=app_state.version,
            )
            // Use relay_message to forward
            ignore(relay_message(transport, from, ping_msg, peer_id))
          }
          None =>
            log_debug(
              "DEBUG: heartbeat peer no conns peer=\{peer_id} protocol=\{transport.protocol()}",
            )
        }
      }
      // Send ping to all connections of this peer
      for conn in peer_conns {
        let ping_local_addr = local_addr
        let ping_msg = Message(
          kind="ping",
          source_id=from,
          source_addr=ping_local_addr,
          version=app_state.version,
        )

        // Get all candidate addresses for this peer and protocol
        let candidate_addrs : Array[String] = []
        if get_global_peer_manager().get_peer(peer_id) is Some(peer_node) {
          for addr in peer_node.addresses {
            let target_addr = if addr.contains("://") {
              addr
            } else {
              transport.protocol() + "://" + addr
            }
            if @url.Url::parse(target_addr) is Some(u) &&
              u.scheme == transport.protocol() {
              candidate_addrs.push(target_addr)
            }
          }
        }

        // Also include the currently connected address if known
        // (though it should be in peer_node.addresses usually)

        if candidate_addrs.is_empty() {
          // Fallback to pick_peer_address if no addresses found (e.g. routed?)
          if pick_peer_address(peer_id, transport.protocol()) is Some(addr) {
            candidate_addrs.push(addr)
          }
        }
        for target_addr in candidate_addrs {
          if target_addr != "routed" {
            global_state.connection_manager = global_state.connection_manager.update_connection_address_ping(
              conn.id,
              target_addr,
              current_time,
            )
            // We also update the main ping time for backward compatibility/general health
            global_state.connection_manager = global_state.connection_manager.update_connection_ping_time(
              conn.id,
              Some(current_time),
            )
            global_state.connection_manager = global_state.connection_manager.update_connection_packet_loss(
              conn.id,
              1,
              0,
            )
            let ok = send_message(transport, target_addr, ping_msg)
            if !ok {
              global_state.connection_manager = global_state.connection_manager.mark_connection_address_packet_lost(
                conn.id,
                target_addr,
              )
            }
            log_debug(
              "DEBUG: ping send protocol=\{transport.protocol()} peer=\{peer_id} addr=\{target_addr} ok=\{ok}",
            )
          }
        }
        if conn.relay == 1 {
          global_state.connection_manager = global_state.connection_manager.prune_connection_ports(
            conn.id,
            current_time,
            server_state.connection_timeout_ms,
          )
        }
        let ping_timeout = match conn.last_ping_time {
          Some(ping_time) => {
            let pong_ok = match conn.last_pong_time {
              Some(pong_time) => pong_time >= ping_time
              None => false
            }
            current_time - ping_time > server_state.connection_timeout_ms &&
            !pong_ok
          }
          None => false
        }
        if ping_timeout && conn.relay == 1 {
          let target_addr = pick_peer_address(peer_id, transport.protocol()).unwrap_or(
            "",
          )
          log_warn("Connection to \{peer_id} at \{target_addr} timed out")
          global_state.connection_manager = global_state.connection_manager.remove_connection(
            conn.id,
          )
          log_debug(
            "DEBUG: heartbeat timeout broadcast protocol=\{transport.protocol()} peer=\{peer_id}",
          )
          needs_broadcast = true
        }
      }

      // Check if peer has any active connections left
      let remaining_conns = get_global_connection_manager().get_peer_connections(
        peer_id,
      )
      if remaining_conns.is_empty() {
        // Check if we have a valid route
        let _ = match get_global_peer_manager().get_route(peer_id) {
          Some(_) => true
          None => false
        }

        // Double check if we should remove the peer
        // Only remove if it's not our own ID (though get_all_peers shouldn't include self usually)
        // AND if we don't have a route (or maybe we should timeout route too?)
        // Currently we rely on sync messages to refresh routes.
        // If we haven't received sync from this peer (via relay) for a while, the route might be stale?
        // Route struct has timestamp.

        // Let's check route timeout if it exists
        let route_expired = match get_global_peer_manager().get_route(peer_id) {
          Some(route) => {
            let now = @env.now()
            // 30s timeout for routes? Or use server_state.connection_timeout_ms?
            now - route.timestamp > server_state.connection_timeout_ms
          }
          None => true // No route, effectively expired/non-existent
        }
        if peer_id != from && route_expired {
          log_warn(
            "Peer \{peer_id} has no active connections and route expired/missing, removing peer.",
          )
          global_state.peer_manager = global_state.peer_manager.remove_peer(
            peer_id,
          )
          needs_broadcast = true
        }
      }
    }
    if needs_broadcast {
      ignore(broadcast_sync(from, local_addr))
    }
  }
}

///|
fn broadcast_sync(my_id : String, local_addr : String) -> Unit {
  let now = @env.now()
  if now - server_state.last_sync_broadcast_time < 1000 {
    log_debug(
      "DEBUG: broadcast_sync throttled (last was \{now - server_state.last_sync_broadcast_time}ms ago)",
    )
    return
  }
  server_state.last_sync_broadcast_time = now
  // Create base message to reuse body
  let base_msg = create_sync_message(my_id, local_addr)
  let all_peers = get_global_peer_manager().get_all_peers()
  log_debug(
    "DEBUG: broadcast_sync from=\{my_id} local=\{local_addr} peers=\{all_peers.length()}",
  )
  for peer in all_peers {
    // Create individual message for each peer to ensure single delivery
    // Reuse body from base_msg to avoid recomputing connections
    let msg = Message(
      kind="sync",
      source_id=my_id,
      source_addr=local_addr,
      target_id=peer.id,
      body=base_msg.body,
      version=app_state.version,
    )
    log_debug("DEBUG: broadcast_sync enqueue to=\{peer.id} msg=\{msg.id}")
    ignore(add_pending_message(msg))
  }
}

///|
async fn handle_periodic_updates(my_id : String, local_addr : String) -> Unit {
  let update_interval = 10000 // 10 seconds
  log_debug(
    "DEBUG: handle_periodic_updates start id=\{my_id} local=\{local_addr}",
  )
  for ;; {
    @async.sleep(update_interval)
    log_debug("DEBUG: periodic_updates tick id=\{my_id}")
    broadcast_sync(my_id, local_addr)
  }
}
