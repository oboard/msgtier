///|
const CONNECTION_TIMEOUT_MS : UInt64 = 60000 // 60 seconds timeout

///|
let last_sync_broadcast_time : Ref[UInt64] = Ref::new(0)

///|
fn parse_port_from_addr(addr : String, protocol : String) -> Int? {
  let addr_str = if addr.contains("://") {
    addr
  } else {
    protocol + "://" + addr
  }
  let mut parsed : Address? = None
  try {
    parsed = Some(Address::parse(addr_str))
  } catch {
    _ => ()
  }
  match parsed {
    Some(a) => Some(a.port.to_int())
    None => None
  }
}

///|
fn extract_port_tuple(
  local_addr : String,
  remote_addr : String,
  protocol : String,
) -> (Int, Protocol, Int)? {
  let local_port = parse_port_from_addr(local_addr, protocol)
  let remote_port = parse_port_from_addr(remote_addr, protocol)
  let proto = Protocol::parse(protocol[:])
  match local_port {
    Some(lp) =>
      match remote_port {
        Some(rp) =>
          match proto {
            Some(p) => Some((lp, p, rp))
            None => None
          }
        None => None
      }
    None => None
  }
}

///|
fn handle_new_connection(
  peer_id : String,
  local_addr : String,
  remote_addr : String,
  protocol : String,
  peer_info? : NetworkDiscoveryInfo,
  relay_depth? : Int = 1,
) -> (Connection, Bool, Bool) {
  log_debug(
    "DEBUG: handle_new_connection peer=\{peer_id} local=\{local_addr} remote=\{remote_addr} protocol=\{protocol} relay=\{relay_depth}",
  )
  // Get the actual peer ID (from peer_info if available, otherwise from peer_id parameter)
  let actual_peer_id = if peer_info is Some(info) { info.id } else { peer_id }

  // Prevent connecting to self
  // If we are connecting to ourselves, return a dummy connected connection
  // and do NOT add it to the connection manager.
  let my_id = get_config().id
  if actual_peer_id == my_id && !my_id.is_empty() {
    let dummy_conn = Connection::new(my_id, actual_peer_id)
    log_debug(
      "DEBUG: handle_new_connection self skip peer=\{actual_peer_id} local=\{local_addr} remote=\{remote_addr}",
    )
    return (dummy_conn, false, false)
  }
  let mut is_new_peer = false

  // Add or update peer with provided info
  if peer_info is Some(info) {
    let peer_node = match get_global_peer_manager().get_peer(info.id) {
      Some(existing) =>
        { ..existing, version: info.version, public_key: info.public_key }
      None =>
        PeerNode::new(
          id=info.id,
          version=info.version,
          public_key=info.public_key,
          addresses=[remote_addr],
          metadata={},
        )
    }
    update_global_peer_manager(fn(manager) { manager.add_peer(peer_node) })
    update_global_peer_manager(fn(manager) {
      manager.add_peer_address(info.id, remote_addr)
    })
  } else {
    // Only create peer if it doesn't exist yet
    match get_global_peer_manager().get_peer(actual_peer_id) {
      Some(_) => () // Peer exists, don't override
      None => {
        let peer_node = PeerNode::new(
          id=actual_peer_id,
          version=VERSION,
          public_key=[],
          addresses=[remote_addr],
          metadata={},
        )
        update_global_peer_manager(fn(manager) { manager.add_peer(peer_node) })
        is_new_peer = true
      }
    }
  }

  // Check if connection already exists
  let existing_conns = get_global_connection_manager().get_peer_connections(
    actual_peer_id,
  )
  let port_tuple = if relay_depth == 1 {
    extract_port_tuple(local_addr, remote_addr, protocol)
  } else {
    None
  }
  if !existing_conns.is_empty() {
    let existing_conn = existing_conns[0]
    let should_upgrade = relay_depth < existing_conn.relay
    if should_upgrade {
      update_global_connection_manager(fn(manager) {
        manager.update_connection_relay(existing_conn.id, relay_depth)
      })
    }
    let upgraded_conn = if should_upgrade {
      existing_conn.update_relay(relay_depth)
    } else {
      existing_conn
    }
    let updated_conn = match port_tuple {
      Some((local_port, proto, remote_port)) => {
        let now = @env.now()
        update_global_connection_manager(fn(manager) {
          manager.update_connection_ports(
            existing_conn.id,
            local_port,
            proto,
            remote_port,
            now,
          )
        })
        upgraded_conn.touch_port(local_port, proto, remote_port, now)
      }
      None => upgraded_conn
    }
    log_debug(
      "DEBUG: handle_new_connection reuse peer=\{actual_peer_id} local=\{local_addr} remote=\{remote_addr}",
    )
    return (updated_conn, false, is_new_peer)
  }

  // Add new connection with protocol
  update_global_connection_manager(fn(manager) {
    let my_id = get_config().id
    let new_conn = Connection::new(my_id, actual_peer_id)
    let mgr = manager.add_connection(new_conn)
    mgr.update_connection_relay(new_conn.id, relay_depth)
  })
  log_debug(
    "DEBUG: handle_new_connection added peer=\{actual_peer_id} local=\{local_addr} remote=\{remote_addr}",
  )
  let conn = Connection::new(my_id, actual_peer_id).update_relay(relay_depth)
  let updated_conn = match port_tuple {
    Some((local_port, proto, remote_port)) => {
      let now = @env.now()
      update_global_connection_manager(fn(manager) {
        manager.update_connection_ports(
          conn.id,
          local_port,
          proto,
          remote_port,
          now,
        )
      })
      conn.touch_port(local_port, proto, remote_port, now)
    }
    None => conn
  }
  (updated_conn, true, is_new_peer)
}

///|
async fn handle_reconnects(
  transport : &Transport,
  local_addr : String,
  peer_id : String,
) -> Unit {
  log_debug(
    "DEBUG: handle_reconnects start protocol=\{transport.protocol()} local=\{local_addr} id=\{peer_id}",
  )
  let our_addresses = get_our_addresses(local_addr)
  let reconnect_interval = 5000 // Fixed interval: 5s
  for {
    // Sleep with fixed interval
    @async.sleep(reconnect_interval)

    let hello_msg = create_hello_message(
      peer_id,
      local_addr,
      1,
      peers=our_addresses,
    )

    // Build list of target addresses
    let targets : Map[String, String] = {}

    let peers = get_global_peer_manager().get_all_peers()
    for peer in peers {
      let has_direct_conn = get_global_connection_manager()
        .get_peer_connections(peer.id)
        .any(fn(conn) { conn.relay == 1 })
      if has_direct_conn {
        continue
      }
      for addr_str in peer.addresses {
        let mut parsed : Address? = None
        try {
          parsed = Some(Address::parse(addr_str))
        } catch {
          _ => ()
        }
        match parsed {
          Some(addr) => {
            if addr.protocol != transport.protocol_type() {
              continue
            }
            let key = peer.id +
              "|" +
              addr.protocol.to_string() +
              "|" +
              addr.port.to_string()
            let mut use_new = false
            match targets.get(key) {
              None => use_new = true
              Some(existing) => {
                let mut existing_parsed : Address? = None
                try {
                  existing_parsed = Some(Address::parse(existing))
                } catch {
                  _ => ()
                }
                match existing_parsed {
                  Some(existing_addr) => {
                    let new_loop = is_loopback(addr.host)
                    let old_loop = is_loopback(existing_addr.host)
                    if old_loop && !new_loop {
                      use_new = true
                    } else if !old_loop && new_loop {
                      use_new = false
                    } else {
                      let new_private = is_private(addr.host)
                      let old_private = is_private(existing_addr.host)
                      if old_private && !new_private {
                        use_new = true
                      }
                    }
                  }
                  None => use_new = true
                }
              }
            }
            if use_new {
              targets[key] = addr_str
            }
          }
          None => ()
        }
      }
    }

    let known_peers = get_all_known_peers()
    for addr in known_peers {
      if !addr.contains("0.0.0.0") && !addr.is_empty() {
        let peer_id_opt = get_global_peer_manager().get_peer_id_by_address(addr)
        let mut parsed : Address? = None
        try {
          parsed = Some(Address::parse(addr))
        } catch {
          _ => ()
        }
        match parsed {
          Some(a) =>
            if a.protocol == transport.protocol_type() {
              match peer_id_opt {
                Some(pid) => {
                  let has_direct_conn = get_global_connection_manager()
                    .get_peer_connections(pid)
                    .any(fn(conn) { conn.relay == 1 })
                  if has_direct_conn {
                    continue
                  }
                  let key = pid +
                    "|" +
                    a.protocol.to_string() +
                    "|" +
                    a.port.to_string()
                  match targets.get(key) {
                    Some(_) => ()
                    None => targets[key] = addr
                  }
                }
                None =>
                  match targets.get(addr) {
                    Some(_) => ()
                    None => targets[addr] = addr
                  }
              }
            }
          None =>
            match targets.get(addr) {
              Some(_) => ()
              None => targets[addr] = addr
            }
        }
      }
    }

    // Process each target
    for _, peer_addr in targets {
      if !peer_addr.has_prefix(transport.protocol() + "://") {
        continue
      }
      log_debug(
        "DEBUG: reconnect hello protocol=\{transport.protocol()} from=\{local_addr} to=\{peer_addr}",
      )
      send_message(transport, peer_addr, hello_msg) |> ignore
    }
  }
}

///|
async fn handle_pending_messages(
  root : @async.TaskGroup[Unit],
  transport : &Transport,
  my_id : String,
) -> Unit {
  let protocol_prefix = transport.protocol() + "://"
  let local_addr = transport.protocol() + "://" + transport.local_addr()
  log_debug(
    "DEBUG: handle_pending_messages start protocol=\{transport.protocol()} prefix=\{protocol_prefix}",
  )
  for {
    // Check for pending messages every 100ms
    @async.sleep(100)
    // Only take messages we can handle:
    // 1. Specific protocol match (e.g. tcp://...)
    // 2. No protocol (peer ID) - we try to route these
    let pending = take_pending_messages(fn(_) { true })
    if pending.is_empty() {
      continue
    }
    log_debug(
      "DEBUG: pending batch protocol=\{transport.protocol()} count=\{pending.length()}",
    )

    // Process each pending message
    for entry in pending {
      let pending_msg = entry.msg
      let cm = get_global_connection_manager()
      let mut sent = false
      let target_peer_ids = if pending_msg.is_broadcast() {
        get_global_peer_manager().get_all_peers().map(p => p.id)
      } else {
        match pending_msg.target_id {
          Some(target_id) => [target_id]
          None => get_global_peer_manager().get_all_peers().map(p => p.id)
        }
      }
      for target_peer_id in target_peer_ids {
        // Handle loopback (send to self)
        if target_peer_id == my_id {
          // Attempt to remove message atomically (returns true if we removed it)
          // This prevents multiple transports from handling the same local message
          if remove_pending_message(pending_msg) {
            log_info(
              "PendingMessage: handling local loopback id=\{pending_msg.id}",
            )
            // Use spawn_bg to avoid blocking the pending loop
            root.spawn_bg(async fn() {
              handle_incoming_message(
                pending_msg.to_msgpack(),
                local_addr,
                my_id,
                local_addr,
                root,
                transport,
              )
            })
          }
          continue
        }
        let target_connections = cm.get_peer_connections(target_peer_id)
        if target_connections.is_empty() {
          match pick_peer_lan_address(target_peer_id, transport.protocol()) {
            Some(addr) => {
              let target_addr = if addr.contains("://") {
                addr
              } else {
                transport.protocol() + "://" + addr
              }
              if !target_addr.is_empty() && target_addr != "routed" {
                let msg = pending_msg
                log_debug(
                  "PendingMessage: lan addr=\{target_addr} id=\{msg.id}",
                )
                let success = send_message(transport, target_addr, msg)
                log_debug(
                  "DEBUG: pending lan send protocol=\{transport.protocol()} addr=\{target_addr} id=\{msg.id} ok=\{success}",
                )
                if success {
                  sent = true
                  mark_pending_message_sent(
                    pending_msg.id,
                    target_peer_id,
                    transport.protocol(),
                    [transport.protocol()],
                  )
                  |> ignore
                }
              }
            }
            None => ()
          }
          if sent {
            continue
          }
          // For broadcast messages, do not use unicast routing to avoid duplicates and type confusion
          if pending_msg.is_broadcast() {
            continue
          }
          // Check if we have a route for this peer
          match get_global_peer_manager().get_route(target_peer_id) {
            Some(route) => {
              // Try to relay
              log_debug(
                "DEBUG: pending relay to=\{target_peer_id} via=\{route.next_hop}",
              )
              // Relay message handles finding connection to next_hop for current transport
              let relayed = relay_message(
                transport, my_id, pending_msg, target_peer_id,
              )
              if relayed {
                sent = true
                // Mark as sent for this protocol
                mark_pending_message_sent(
                  pending_msg.id,
                  target_peer_id,
                  transport.protocol(),
                  [transport.protocol()], // Just this protocol
                )
                |> ignore
              }
            }
            None =>
              log_debug(
                "DEBUG: pending no connections and no route protocol=\{transport.protocol()} target=\{target_peer_id} id=\{pending_msg.id}",
              )
          }
          continue
        }

        if pending_msg.kind == "sync" &&
          entry.sent_targets.get(target_peer_id) is Some(m) &&
          m.length() > 0 {
          continue
        }
        if entry.sent_targets.get(target_peer_id) is Some(m) &&
          m.contains(transport.protocol()) {
          continue
        }
        let target_addr = match
          pick_peer_address(target_peer_id, transport.protocol()) {
          Some(addr) =>
            if addr.contains("://") {
              addr
            } else {
              transport.protocol() + "://" + addr
            }
          None => ""
        }
        if !target_addr.is_empty() && target_addr != "routed" {
          let msg = pending_msg
          log_debug("PendingMessage: direct addr=\{target_addr} id=\{msg.id}")
          let success = send_message(transport, target_addr, msg)
          log_debug(
            "DEBUG: pending send protocol=\{transport.protocol()} addr=\{target_addr} id=\{msg.id} ok=\{success}",
          )
          if success {
            sent = true
          }
        }
        if sent {
          let required_protocols = [transport.protocol()]
          log_debug(
            "DEBUG: pending mark sent id=\{pending_msg.id} protocol=\{transport.protocol()}",
          )
          mark_pending_message_sent(
            pending_msg.id,
            target_peer_id,
            transport.protocol(),
            required_protocols,
          )
          |> ignore
        } else if target_connections.length() > 0 {
          // If we have connections but failed to send on this specific transport
          log_debug(
            "DEBUG: pending failed to send on any connection protocol=\{transport.protocol()} target=\{target_peer_id} id=\{pending_msg.id}",
          )
          ()
        }
      }
    }
  }
}

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
  for {
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
            let ping_msg = Message::new(
              kind="ping",
              source_id=from,
              source_addr=local_addr,
              version=VERSION,
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
        let ping_msg = Message::new(
          kind="ping",
          source_id=from,
          source_addr=ping_local_addr,
          version=VERSION,
        )
        match pick_peer_address(peer_id, transport.protocol()) {
          Some(addr) => {
            let target_addr = if addr.contains("://") {
              addr
            } else {
              transport.protocol() + "://" + addr
            }
            if target_addr != "routed" {
              update_global_connection_manager(fn(manager) {
                manager.update_connection_ping_time(conn.id, Some(current_time))
              })
              update_global_connection_manager(fn(manager) {
                manager.update_connection_packet_loss(conn.id, 1, 0)
              })
              let ok = send_message(transport, target_addr, ping_msg)
              log_debug(
                "DEBUG: ping send protocol=\{transport.protocol()} peer=\{peer_id} addr=\{target_addr} ok=\{ok}",
              )
            }
          }
          None => ()
        }

        if conn.relay == 1 {
          update_global_connection_manager(fn(manager) {
            manager.prune_connection_ports(
              conn.id,
              current_time,
              CONNECTION_TIMEOUT_MS,
            )
          })
        }

        let ping_timeout = match conn.last_ping_time {
          Some(ping_time) => {
            let pong_ok = match conn.last_pong_time {
              Some(pong_time) => pong_time >= ping_time
              None => false
            }
            current_time - ping_time > CONNECTION_TIMEOUT_MS && !pong_ok
          }
          None => false
        }
        if ping_timeout && conn.relay == 1 {
          let target_addr = pick_peer_address(peer_id, transport.protocol()).unwrap_or(
            "",
          )
          log_warn("Connection to \{peer_id} at \{target_addr} timed out")
          update_global_connection_manager(fn(manager) {
            manager.remove_connection(conn.id)
          })
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
            // 30s timeout for routes? Or use CONNECTION_TIMEOUT_MS?
            now - route.timestamp > CONNECTION_TIMEOUT_MS
          }
          None => true // No route, effectively expired/non-existent
        }
        if peer_id != from && route_expired {
          log_warn(
            "Peer \{peer_id} has no active connections and route expired/missing, removing peer.",
          )
          update_global_peer_manager(fn(manager) {
            manager.remove_peer(peer_id)
          })
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
  if now - last_sync_broadcast_time.val < 1000 {
    log_debug(
      "DEBUG: broadcast_sync throttled (last was \{now - last_sync_broadcast_time.val}ms ago)",
    )
    return
  }
  last_sync_broadcast_time.val = now
  let update_msg = create_sync_message(my_id, local_addr)
  let all_peers = get_global_peer_manager().get_all_peers()
  log_debug(
    "DEBUG: broadcast_sync from=\{my_id} local=\{local_addr} peers=\{all_peers.length()}",
  )
  for peer in all_peers {
    log_debug(
      "DEBUG: broadcast_sync enqueue to=\{peer.id} msg=\{update_msg.id}",
    )
    ignore(add_pending_message(update_msg))
  }
}

///|
async fn handle_periodic_updates(my_id : String, local_addr : String) -> Unit {
  let update_interval = 10000 // 10 seconds
  log_debug(
    "DEBUG: handle_periodic_updates start id=\{my_id} local=\{local_addr}",
  )
  for {
    @async.sleep(update_interval)
    log_debug("DEBUG: periodic_updates tick id=\{my_id}")
    broadcast_sync(my_id, local_addr)
  }
}

///|
async fn handle_incoming_message(
  bytes : Bytes,
  sender_addr : String,
  id : String,
  local_addr : String,
  root : @async.TaskGroup[Unit],
  transport : &Transport,
) -> Unit noraise {
  let msgpack_value = @msgpack.decode(bytes) catch {
    e => {
      let error_msg = e.to_string()
      log_debug(
        "DEBUG: Msgpack decode error - \{error_msg}, sender: \{sender_addr}, bytes: \{bytes.length()}",
      )
      return
    }
  }
  let msg : Message = Message::from_msgpack(msgpack_value) catch {
    _ => {
      log_warn(
        "Failed to decode message: \{msgpack_value.to_json().stringify()}",
      )
      return
    }
  }
  // Skip messages from self, unless target is self
  if msg.source_id == id && msg.target_id != Some(id) {
    return
  }
  let msg = decrypt_message_body(transport, id, local_addr, msg)
  guard msg is Some(msg) else { return }
  if !msg.encrypted {
    if msg.kind == "object_request" {
      root.spawn_bg(async fn() { handle_object_request(msg) })
    } else if msg.kind == "object_response" {
      handle_object_response(msg)
    } else {
      root.spawn_bg(async fn() { emit_ws_message(msg) })
    }
  }
  // Logger
  log_info(
    "[\{msg.kind}]\t\{msg.source_id}(\{sender_addr})" +
    (if msg.relay > 1 { " relay=\{msg.relay}" } else { "" }),
  )
  log_debug(
    "DEBUG: incoming protocol=\{transport.protocol()} local=\{local_addr} sender=\{sender_addr} kind=\{msg.kind} id=\{msg.id}",
  )
  // Handle the connection - always create/update connection for any message
  // Determine connectable address from hello message
  let connectable_addr = if msg.kind == "hello" &&
    msg.source_addr is Some(source_addr) {
    // Ensure address has protocol
    let addr_str = if source_addr.contains("://") {
      source_addr
    } else {
      transport.protocol() + "://" + source_addr
    }
    match @url.Url::parse(addr_str) {
      Some(url) => {
        let host = url.hostname()
        if host == "0.0.0.0" || host == "" {
          // Extract IP from sender (IP:Port or URL)
          let sender_ip = match @url.Url::parse(sender_addr) {
            Some(u) => u.hostname()
            None => {
              // Fallback for non-URL sender_addr (should not happen with updated transports)
              let mut idx = -1
              for i = 0; i < sender_addr.length(); i = i + 1 {
                if sender_addr[i] == ':' {
                  idx = i
                }
              }
              if idx != -1 {
                sender_addr[:idx].to_string() catch {
                  _ => sender_addr
                }
              } else {
                sender_addr
              }
            }
          }
          url.set_hostname(sender_ip)
          url.to_string()
        } else {
          addr_str
        }
      }
      None => addr_str
    }
  } else {
    ""
  }

  // If we found a connectable address, add it to known peers
  if !connectable_addr.is_empty() {
    add_known_peer(connectable_addr)
  }
  let peer_info = match msg {
    { kind: "hello", public_key: Some(public_key), .. } => {
      // Get our own listening addresses to prevent attributing them to peers
      let my_listeners = get_our_addresses(local_addr).map(fn(a) { a.address })
      let addrs : Array[NetworkAddress] = []

      // Helper to add unique non-self address
      let add_if_valid = fn(addr : String) {
        if !my_listeners.contains(addr) &&
          !addrs.iter().any(fn(a) { a.address == addr }) {
          addrs.push(NetworkAddress::{ address: addr })
        }
      }
      add_if_valid(sender_addr)
      if !connectable_addr.is_empty() {
        add_if_valid(connectable_addr)
      }

      Some(NetworkDiscoveryInfo::{
        id: msg.source_id,
        version: match msg.version {
          Some(v) => v
          None => VERSION
        },
        addresses: addrs,
        peers: msg.peers,
        public_key,
      })
    }
    _ => None
  }

  // Always handle connection, even if peer_info is None
  // Use the message's relay count as the hop depth for this connection
  // msg.relay already indicates how many hops the message took to reach us
  let relay_depth_to_use = msg.relay
  let effective_addr = sender_addr
  let (conn, is_new_connection, is_new_peer) = handle_new_connection(
    msg.source_id,
    local_addr,
    effective_addr,
    transport.protocol(),
    peer_info?,
    relay_depth=relay_depth_to_use,
  )
  log_debug(
    "DEBUG: connection handled peer=\{msg.source_id} local=\{local_addr} remote=\{effective_addr} protocol=\{transport.protocol()} new=\{is_new_connection}",
  )
  // let now = @env.now()
  // let diff = if now >= conn.last_seen { now - conn.last_seen } else { 0UL }

  let should_skip_hello_callback = if msg.kind == "hello" {
    let hello_key = msg.source_id + "|" + sender_addr
    check_and_mark_hello(hello_key, 5000UL)
  } else {
    false
  }

  // Store peer's public key if provided and compute shared secret (only if not already stored)
  if msg.public_key is Some(pk) {
    compute_and_store_shared_secret(msg.source_id, pk)
  }

  // Reply to hello if it's a new connection or new peer (key update), to ensure bidirectional key exchange.
  if (is_new_connection || is_new_peer) &&
    msg.kind == "hello" &&
    !should_skip_hello_callback {
    let our_addresses = get_our_addresses(local_addr)
    let hello_msg = create_hello_message(id, local_addr, 1, peers=our_addresses)
    let target_addr = effective_addr
    let target_addr_full = if target_addr.contains("://") {
      target_addr
    } else {
      transport.protocol() + "://" + target_addr
    }
    // Don't log here to avoid spam, debug log is enough
    log_debug(
      "DEBUG: Replying hello to \{target_addr_full} (new_conn=\{is_new_connection}, new_peer=\{is_new_peer})",
    )
    ignore(send_message(transport, target_addr_full, hello_msg))
  }

  // Track bytes received
  update_global_connection_manager(fn(manager) {
    manager.update_connection_bytes(conn.id, 0UL, bytes.length().to_uint64())
  })

  // Update last_seen timestamp
  update_global_connection_manager(fn(manager) {
    let timestamp = @env.now()
    manager.update_connection_last_seen(conn.id, timestamp)
  })

  // Only broadcast connection update if this is a NEW connection established via Hello
  // This prevents sync storms where sync messages on ephemeral connections trigger more syncs
  if is_new_connection && msg.kind == "hello" {
    // Check if we already have other connections to this peer
    let peer_conns = get_global_connection_manager().get_peer_connections(
      msg.source_id,
    )
    // Only broadcast if this is the FIRST connection (count == 1)
    // If we already have connections (count > 1), we don't need to spam the network
    if peer_conns.length() == 1 {
      log_debug(
        "DEBUG: new connection broadcast_sync peer=\{msg.source_id} local=\{local_addr}",
      )
      broadcast_sync(id, local_addr)
    } else {
      log_debug(
        "DEBUG: secondary connection established peer=\{msg.source_id} count=\{peer_conns.length()} - skipping broadcast_sync",
      )
    }
  }

  // Handle message relaying: if target is set and we're not the target, forward it
  if msg.target_id is Some(target_peer_id) {
    if global_config.val is Some({ id, .. }) && id == target_peer_id {
      // Message is for us, continue to process
    } else {
      // Message is for someone else, forward it
      ignore(
        relay_message(transport, id, msg, target_peer_id, allow_queueing=true),
      )
    }
  }

  // Handle broadcast forwarding: if broadcast is true, forward to all peers (except sender)
  if msg.is_broadcast() &&
    msg.source_id != id &&
    !msg.visited.any(fn(peer_id) { peer_id == id }) {
    // Add current node to visited list to track the path and prevent loops
    let updated_visited = msg.visited
    updated_visited.push(id)

    // Get all known peers and send broadcast to each (except sender)
    let known_peers = get_all_known_peers()
    for peer_addr in known_peers {
      if peer_addr != sender_addr && !peer_addr.has_prefix("0.0.0.0:") {
        let broadcast_msg = Message::{
          ..msg,
          relay: msg.relay + 1,
          visited: updated_visited,
          target_id: None,
        }
        ignore(send_message(transport, peer_addr, broadcast_msg))
        // println("[broadcast]\t\{msg.from}(\{sender_addr}) -> \{peer_addr}")
      }
    }
  }
  // Log all received messages for debugging
  // log_info("RAW MSG: kind=\{msg.kind} from=\{msg.source_id}")

  if msg.kind != "ping" && msg.kind != "pong" {
    let pk_status = match msg.public_key {
      Some(_) => "with_pk"
      None => "no_pk"
    }
    if !(msg.kind == "hello" && should_skip_hello_callback) {
      log_info("Received \{msg.kind} from \{msg.source_id} (\{pk_status})")
    }
  }
  match msg {
    { kind: "hello", peers: advertised_peers, .. } =>
      if should_skip_hello_callback {
        ()
      } else {
        // Logic for hello with optional public_key and secret validation
        let mut secret_matched = false
        let secret_valid = match global_config.val {
          Some(config) => {
            let our_secret_hash = bytes_to_hex(hash_secret(config.secret))
            match msg.secret_hash {
              Some(peer_secret_hash) =>
                if peer_secret_hash == our_secret_hash {
                  secret_matched = true
                  true
                } else {
                  log_warn(
                    "Warning: Peer \{msg.source_id} secret mismatch. Expected: \{our_secret_hash}, Got: \{peer_secret_hash}. Allowing connection.",
                  )
                  true
                }
              None => {
                log_warn(
                  "Warning: Peer \{msg.source_id} missing secret hash. Allowing connection.",
                )
                true
              }
            }
          }
          None => true
        }
        if !secret_valid {
          return
        }

        // Determine effective public key
        let effective_pk_opt = match msg.public_key {
          Some(pk) => Some(pk)
          None =>
            if secret_matched {
              match global_keypair.val {
                Some((_, pk)) => {
                  log_warn(
                    "Warning: Peer \{msg.source_id} missing PK but secret matched. Using our PK as fallback.",
                  )
                  Some(pk)
                }
                None => None
              }
            } else {
              None
            }
        }

        // Ensure peer exists in manager before learning address
        match get_global_peer_manager().get_peer(msg.source_id) {
          None => {
            // Peer doesn't exist yet, create it
            let peer_node = PeerNode::new(
              id=msg.source_id,
              version=VERSION,
              public_key=effective_pk_opt.unwrap_or(b""),
              addresses=if msg.source_addr is Some(addr) { [addr] } else { [] },
              metadata={},
            )
            update_global_peer_manager(fn(manager) {
              manager.add_peer(peer_node)
            })
          }
          Some(existing) =>
            // Update public key if provided and different
            match effective_pk_opt {
              Some(new_pk) =>
                if new_pk.length() > 0 {
                  // Check if key changed or was missing
                  let needs_update = if existing.public_key.length() == 0 {
                    true
                  } else {
                    existing.public_key != new_pk
                  }
                  if needs_update {
                    log_info(
                      "Updating public key for peer \{msg.source_id} (old_len=\{existing.public_key.length()})",
                    )
                    let updated_peer = { ..existing, public_key: new_pk }
                    update_global_peer_manager(fn(manager) {
                      manager.add_peer(updated_peer)
                    })
                    // Clear shared secret to force re-computation with new key
                    clear_shared_secret(msg.source_id)
                  }
                }
              None => ()
            }
        }

        // Always compute and store shared secret when receiving hello
        // This ensures we have the latest shared secret if peer restarted
        match effective_pk_opt {
          Some(pk) => {
            log_debug(
              "DEBUG: Received/Derived Public Key from \{msg.source_id}: \{bytes_to_hex(pk)}",
            )
            compute_and_store_shared_secret(msg.source_id, pk)
          }
          None =>
            log_warn(
              "Cannot compute shared secret for \{msg.source_id}: No Public Key available",
            )
        }

        if advertised_peers is Some(peer_addrs) {
          for peer_addr_obj in peer_addrs {
            let peer_url = peer_addr_obj.address
            if !is_bind_all_address(peer_url) && peer_url != local_addr {
              add_known_peer(peer_url)
            }
          }
        }

        // Re-broadcast hello to all other known peers so they also learn about this peer
        // This ensures peer discovery propagates through the network even for peers
        // we only know via relay paths
        // Debounce: only re-broadcast once per peer per 30 seconds
        if should_rebroadcast_hello(msg.source_id) {
          record_hello_time(msg.source_id)
          let known_peers = get_all_known_peers()
          let targets : Map[String, String] = {}
          for peer_url in known_peers {
            if peer_url != sender_addr && !is_bind_all_address(peer_url) {
              let peer_id_opt = get_global_peer_manager().get_peer_id_by_address(
                peer_url,
              )
              let mut parsed : Address? = None
              try {
                parsed = Some(Address::parse(peer_url))
              } catch {
                _ => ()
              }
              match parsed {
                Some(a) =>
                  if a.protocol == transport.protocol_type() {
                    let key = match peer_id_opt {
                      Some(pid) =>
                        pid +
                        "|" +
                        a.protocol.to_string() +
                        "|" +
                        a.port.to_string()
                      None => peer_url
                    }
                    match targets.get(key) {
                      Some(_) => ()
                      None => targets[key] = peer_url
                    }
                  }
                None =>
                  match targets.get(peer_url) {
                    Some(_) => ()
                    None => targets[peer_url] = peer_url
                  }
              }
            }
          }
          for _, peer_url in targets {
            ignore(send_message(transport, peer_url, msg))
          }
        }
      }
    { kind: "text", body: String(text), .. } => {
      log_info("Received text message: \{text}")

      send_response_message(
        id,
        sender_addr,
        msg.source_id,
        msg.payload.unwrap_or(msg.id),
        @msgpack.string(text),
      )
    }
    { kind: "response", payload: Some(correlation_id), body, .. } => {
      let final_data = match body {
        Binary(raw) => decode_binary_payload(raw)
        _ => body
      }
      handle_data_response(correlation_id, final_data, msg.source_id)
    }
    { kind: "response", payload: None, .. } =>
      log_warn(
        "Response message missing payload correlation id from \{msg.source_id}",
      )
    { kind: "ping", .. } => {
      let reply = Message::new(
        kind="pong",
        source_id=id,
        source_addr=local_addr,
        target_id=msg.source_id,
      )
      let ok = send_message(transport, sender_addr, reply)
      log_debug(
        "DEBUG: pong send protocol=\{transport.protocol()} to=\{sender_addr} ok=\{ok}",
      )
    }
    { kind: "pong", .. } => {
      // Heartbeat response received - mark connection as healthy
      let peer_id = msg.source_id
      log_debug(
        "DEBUG: pong recv protocol=\{transport.protocol()} from=\{sender_addr} peer=\{peer_id}",
      )
      let peer_conns = get_global_connection_manager().get_peer_connections(
        peer_id,
      )
      // Find the connection that matches this sender and update its last_seen
      for conn in peer_conns {
        let current_time = @env.now()
        // Calculate RTT if we have a ping timestamp
        match conn.last_ping_time {
          Some(ping_time) => {
            let rtt_ms = (current_time - ping_time).to_int()
            update_global_connection_manager(fn(manager) {
              manager.update_connection_latency(conn.id, rtt_ms)
            })
          }
          None => ()
        }
        update_global_connection_manager(fn(manager) {
          manager.update_connection_pong_time(conn.id, Some(current_time))
        })
        update_global_connection_manager(fn(manager) {
          manager.update_connection_last_seen(conn.id, current_time)
        })
      }
    }
    { kind: "file_request", body, .. } => {
      let object_id = match body {
        String(s) => s
        _ => ""
      }
      let data_opt = get_object(object_id) catch { _ => None }
      match data_opt {
        Some(data) =>
          send_response_message(
            id,
            local_addr,
            msg.source_id,
            msg.payload.unwrap_or(msg.id),
            @msgpack.binary(data),
          )
        None => log_warn("File request for unknown object \{object_id}")
      }
    }
    { kind: "script", body, .. } =>
      handle_script_message(root, id, local_addr, msg, body)
    { kind: "sync", body: Array(conn_entries), .. } => {
      let sender_connections : Array[PeerConnectionInfo] = []
      if msg.peers is Some(peer_addrs) {
        let known_list : Array[String] = []
        for peer_addr_obj in peer_addrs {
          if peer_addr_obj.address != local_addr {
            known_list.push(peer_addr_obj.address)
          }
        }
        add_known_peers(known_list)
      }

      // Parse connection entry: [..., public_key]
      for entry in conn_entries {
        let (conn_val, pk_bytes) = match entry {
          Array(arr) =>
            if arr.length() >= 21 {
              // 20 fields + PK
              let pk_val = arr[20]
              let pk = match pk_val {
                Binary(b) => b
                _ => []
              }
              // Construct a new array with first 20 elements for Connection::from_msgpack
              let conn_arr = []
              for i = 0; i < 20; i = i + 1 {
                conn_arr.push(arr[i])
              }
              (@msgpack.array(conn_arr), pk)
            } else {
              (entry, [])
            }
          _ => (entry, [])
        }
        match Connection::from_msgpack(conn_val) {
          Some(conn) => {
            let peer_id = conn.peer_id
            let relay_depth = conn.relay
            log_debug(
              "DEBUG: sync entry peer=\{peer_id} relay=\{relay_depth} source=\{msg.source_id}",
            )

            // If relay_depth is 1, it's a direct neighbor of the sender
            if relay_depth == 1 && peer_id != msg.source_id {
              sender_connections.push(PeerConnectionInfo::{
                peer_id,
                latency_ms: conn.latency_ms,
                bandwidth_mbps: conn.bandwidth_mbps,
                packet_loss_rate: conn.packet_loss_rate,
                id: conn.id,
                ports: conn.ports,
                last_seen: conn.last_seen,
                quality: conn.quality,
                relay: conn.relay,
                metadata: conn.metadata,
                latency_history: conn.latency_history,
                packets_sent: conn.packets_sent,
                packets_lost: conn.packets_lost,
                bytes_sent: conn.bytes_sent,
                bytes_received: conn.bytes_received,
                last_ping_time: conn.last_ping_time,
                nat_type: conn.nat_type,
              })
            }

            // If the peer is not me
            if peer_id != id {
              // Update Routing Table
              // We learned that 'peer_id' is reachable via 'msg.from' with hops = relay_depth + 1
              // (Since relay_depth is the distance from msg.from to peer_id)
              let new_hops = relay_depth + 1
              log_debug(
                "DEBUG: update_route target=\{peer_id} via=\{msg.source_id} hops=\{new_hops}",
              )
              update_global_peer_manager(fn(manager) {
                manager.update_route(peer_id, msg.source_id, new_hops)
              })

              // Ensure peer exists in manager (even if only known via route)
              match get_global_peer_manager().get_peer(peer_id) {
                None => {
                  let peer_node = PeerNode::new(
                    id=peer_id,
                    version=conn.version,
                    public_key=pk_bytes,
                    addresses=[],
                    metadata={},
                  )
                  update_global_peer_manager(fn(manager) {
                    manager.add_peer(peer_node)
                  })
                }
                Some(_) =>
                  // Update Public Key if we have a better one
                  if pk_bytes.length() > 0 {
                    // Check if key changed
                    let needs_clear_secret = match
                      get_global_peer_manager().get_peer(peer_id) {
                      Some(existing_peer) =>
                        existing_peer.public_key.length() > 0 &&
                        existing_peer.public_key != pk_bytes
                      None => false
                    }
                    update_global_peer_manager(fn(manager) {
                      manager.update_peer_public_key(peer_id, pk_bytes)
                    })
                    if needs_clear_secret {
                      log_info(
                        "Updating public key for peer \{peer_id} via sync (key changed)",
                      )
                      clear_shared_secret(peer_id)
                    }
                  }
              }
            }
          }
          None => ()
        }
      }

      // Update sender's connections in PeerManager
      if !sender_connections.is_empty() {
        update_global_peer_manager(fn(manager) {
          manager.update_peer_connections(msg.source_id, sender_connections)
        })
      }
    }
    _ => ()
  }
}

///|
async fn start_listener_service(
  root : @async.TaskGroup[Unit],
  transport : &Transport,
  my_id : String,
) -> Unit {
  let local_addr = transport.protocol() + "://" + transport.local_addr()
  log_debug(
    "DEBUG: start_listener_service protocol=\{transport.protocol()} local=\{local_addr} id=\{my_id}",
  )

  // Start reconnection background task
  root.spawn_bg(() => handle_reconnects(transport, local_addr, my_id))
  // Start heartbeat/health check background task
  root.spawn_bg(() => handle_heartbeat(transport, local_addr, my_id))
  // Start pending message sender background task
  root.spawn_bg(() => handle_pending_messages(root, transport, my_id))
  // Start periodic connection update task
  root.spawn_bg(() => handle_periodic_updates(my_id, local_addr))

  // Listen loop
  transport.listen(
    root,
    fn(bytes, sender) {
      let sender = transport.protocol() + "://" + sender
      root.spawn_bg(async fn() {
        handle_incoming_message(
          bytes, sender, my_id, local_addr, root, transport,
        )
      })
    },
    fn(remote_addr) {
      let remote_addr = transport.protocol() + "://" + remote_addr
      match get_global_peer_manager().get_peer_id_by_address(remote_addr) {
        Some(peer_id) => {
          let conns = get_global_connection_manager().get_peer_connections(
            peer_id,
          )
          for conn in conns {
            if conn.relay == 1 {
              update_global_connection_manager(fn(manager) {
                manager.remove_connection(conn.id)
              })
              log_warn("[disconnect]\t\{conn.peer_id}(\{remote_addr})")
            }
          }
        }
        None => ()
      }
    },
  )
}
