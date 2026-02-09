///|
const CONNECTION_TIMEOUT_MS : UInt64 = 30000 // 30 seconds timeout

///|
let last_sync_broadcast_time : Ref[UInt64] = Ref::new(0)

///|
fn handle_new_connection(
  peer_id : String,
  local_addr : String,
  remote_addr : String,
  protocol : String,
  peer_info? : NetworkDiscoveryInfo,
  relay_depth? : Int = 1,
  session_id? : String,
) -> (Connection, Bool, Bool) {
  log_debug(
    "DEBUG: handle_new_connection peer=\{peer_id} local=\{local_addr} remote=\{remote_addr} protocol=\{protocol} relay=\{relay_depth} session=\{session_id}",
  )
  // Get the actual peer ID (from peer_info if available, otherwise from peer_id parameter)
  let actual_peer_id = if peer_info is Some(info) { info.id } else { peer_id }

  // Prevent connecting to self
  // If we are connecting to ourselves, return a dummy connected connection
  // and do NOT add it to the connection manager.
  let my_id = get_config().id
  if actual_peer_id == my_id && !my_id.is_empty() {
    let dummy_conn = Connection::new(
      my_id,
      actual_peer_id,
      local_addr,
      remote_addr,
      protocol,
      session_id?,
    )
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

    // Add all addresses provided in peer_info to the peer manager
    for addr_obj in info.addresses {
      update_global_peer_manager(fn(manager) {
        manager.add_peer_address(info.id, addr_obj.address)
      })
    }
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
  for existing_conn in existing_conns {
    if existing_conn.local_addr == local_addr &&
      existing_conn.remote_addr == remote_addr {
      // Connection already exists, return it with is_new=false
      log_debug(
        "DEBUG: handle_new_connection reuse peer=\{actual_peer_id} local=\{local_addr} remote=\{remote_addr}",
      )
      return (existing_conn, false, is_new_peer)
    }
  }

  // For TCP, if this is not a discovery message (no peer_info),
  // try to reuse any existing TCP connection to this peer.
  // This handles the case where incoming messages come from ephemeral ports
  // but should be mapped to the stable listening connection.
  if protocol == "tcp" && peer_info is None {
    for existing_conn in existing_conns {
      if existing_conn.protocol == "tcp" &&
        existing_conn.local_addr == local_addr {
        log_debug(
          "DEBUG: handle_new_connection tcp reuse peer=\{actual_peer_id} local=\{local_addr} remote=\{remote_addr}",
        )
        return (existing_conn, false, is_new_peer)
      }
    }
  }

  // Add new connection with protocol
  update_global_connection_manager(fn(manager) {
    let my_id = get_config().id
    let mgr = manager.add_connection(
      Connection::new(
        my_id,
        actual_peer_id,
        local_addr,
        remote_addr,
        protocol,
        session_id?,
      ),
    )
    // Update relay depth for the new connection
    let new_conns = mgr.get_peer_connections(actual_peer_id)
    let mut updated_mgr = mgr
    for conn in new_conns {
      if conn.local_addr == local_addr && conn.remote_addr == remote_addr {
        updated_mgr = mgr.update_connection_relay(conn.id, relay_depth)
        break
      }
    }
    updated_mgr
  })
  // Get the connection we just added
  let conns = get_global_connection_manager().get_peer_connections(
    actual_peer_id,
  )
  let filtered = conns.filter(fn(c) {
    c.local_addr == local_addr && c.remote_addr == remote_addr
  })
  let conn = if filtered.is_empty() { conns[0] } else { filtered[0] }
  log_debug(
    "DEBUG: handle_new_connection added peer=\{actual_peer_id} local=\{local_addr} remote=\{remote_addr}",
  )
  (conn, true, is_new_peer)
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
  // Generate a random session_id for the new connection attempt
  let session_id = @uuidm.v4_with_rng(
    @uuidm.SimpleRng::new(@env.now().reinterpret_as_int64()),
  ).to_string_simple()
  let hello_msg = create_hello_message(
    peer_id,
    local_addr,
    1,
    peers=our_addresses,
    session_id~,
  )
  let reconnect_interval = 5000 // Fixed interval: 5s
  for {
    // Sleep with fixed interval
    @async.sleep(reconnect_interval)

    // Get current connections once for this iteration
    let current_conns = get_global_connection_manager()
      .get_all_connections()
      .filter(conn => conn.peer_id == peer_id)

    // Build list of target addresses
    let targets = @set.new()

    // 1. Add known peers
    let known_peers = get_all_known_peers()
    for addr in known_peers {
      if !addr.contains("0.0.0.0") && !addr.is_empty() {
        targets.add(addr)
      }
    }

    // 2. Add addresses from existing connections (if not 0.0.0.0)
    for conn in current_conns {
      let addr = conn.remote_addr
      if !addr.contains("0.0.0.0") && !addr.is_empty() {
        targets.add(addr)
      }
    }

    // Process each target
    for peer_addr in targets {
      // Parse URL to check protocol
      if !peer_addr.has_prefix(transport.protocol() + "://") {
        continue
      }
      log_debug(
        "DEBUG: reconnect hello protocol=\{transport.protocol()} from=\{local_addr} to=\{peer_addr}",
      )
      // // Check if we already have an active connection to this peer address
      // let has_active_conn = current_conns.any(conn => conn.remote_addr ==
      //   peer_addr &&
      //   conn.state == ConnectionState::Connected)

      // // Only send hello if we don't have an active connection
      // if !has_active_conn {
      // println("Attempting reconnection to \{peer_addr}...")
      send_message(transport, peer_addr, hello_msg) |> ignore
      // }
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
      let mut pending_msg = entry.msg
      let cm = get_global_connection_manager()
      let mut sent = false
      if !pending_msg.broadcast {
        match pending_msg.target_id {
          Some(target_id) =>
            if !can_direct_connect(target_id) {
              log_debug(
                "Switching to broadcast for message \{pending_msg.id} to \{target_id}",
              )
              set_pending_message_broadcast(pending_msg.id, true)
              pending_msg = { ..pending_msg, broadcast: true }
            }
          None => ()
        }
      }
      let target_peer_ids = if pending_msg.broadcast {
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
            root.spawn_bg(fn() {
              handle_data_message(
                root,
                my_id,
                local_addr,
                pending_msg,
                pending_msg.body,
              )
            })
          }
          continue
        }
        let target_connections = cm.get_peer_connections(target_peer_id)
        if target_connections.is_empty() {
          log_debug(
            "DEBUG: pending no connections protocol=\{transport.protocol()} target=\{target_peer_id} id=\{pending_msg.id}",
          )
          continue
        }
        for target_connection in target_connections {
          if target_connection.protocol != transport.protocol() {
            // log_debug("DEBUG: pending skip protocol mismatch conn=\{target_connection.protocol} transport=\{transport.protocol()} id=\{pending_msg.id}")
            continue
          }
          // Skip if already sent via this protocol
          let already_sent = match entry.sent_targets.get(target_peer_id) {
            Some(m) => m.contains(target_connection.protocol)
            None => false
          }
          if already_sent {
            continue
          }
          let target_addr = target_connection.remote_addr
          let msg = pending_msg

          // Address target: send directly on this transport
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
          let required_protocols = []
          for conn in target_connections {
            if !required_protocols.contains(conn.protocol) {
              required_protocols.push(conn.protocol)
            }
          }
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
        log_debug(
          "DEBUG: heartbeat peer no conns peer=\{peer_id} protocol=\{transport.protocol()}",
        )
      }
      // Send ping to all connections of this peer
      for conn in peer_conns {
        let ping_local_addr = if conn.local_addr.is_empty() {
          local_addr
        } else {
          conn.local_addr
        }
        let ping_msg = Message::new(
          kind="ping",
          source_id=from,
          source_addr=ping_local_addr,
          version=VERSION,
          session_id?=conn.session_id,
        )
        // Record ping time before sending
        update_global_connection_manager(fn(manager) {
          manager.update_connection_ping_time(conn.id, Some(current_time))
        })
        // Increment packets_sent counter
        update_global_connection_manager(fn(manager) {
          manager.update_connection_packet_loss(conn.id, 1, 0)
        })
        if conn.protocol == transport.protocol() {
          let ok = send_message(transport, conn.remote_addr, ping_msg)
          log_debug(
            "DEBUG: ping send protocol=\{transport.protocol()} peer=\{peer_id} addr=\{conn.remote_addr} ok=\{ok}",
          )
        }

        // Check if connection has timed out (no response for CONNECTION_TIMEOUT_MS)
        if current_time - conn.last_seen > CONNECTION_TIMEOUT_MS {
          log_warn("Connection to \{peer_id} at \{conn.remote_addr} timed out")
          update_global_connection_manager(fn(manager) {
            manager.remove_connection(conn.id)
          })
          // Broadcast update because a connection became inactive
          log_debug(
            "DEBUG: heartbeat timeout broadcast protocol=\{transport.protocol()} peer=\{peer_id}",
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
      // Log first 20 bytes for debugging
      if bytes.length() > 0 {
        let preview_len = bytes.length().min(20)
        let preview = bytes[:preview_len]
        log_debug(
          "DEBUG: Message preview (first \{preview_len} bytes): \{bytes_to_hex(preview.to_bytes())}",
        )
      }
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
  // Logger
  log_info("[\{msg.kind}]\t\{msg.source_id}(\{sender_addr})")
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

      // Also include addresses from the hello message payload (the peer's other listeners)
      match msg.peers {
        Some(peers_list) =>
          for p in peers_list {
            add_if_valid(p.address)
          }
        None => ()
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
  let (conn, is_new_connection, _is_new_peer) = handle_new_connection(
    msg.source_id,
    local_addr,
    effective_addr,
    transport.protocol(),
    peer_info?,
    relay_depth=relay_depth_to_use,
    session_id=match msg.session_id {
      Some(sid) => sid
      None => ""
    },
  )
  log_debug(
    "DEBUG: connection handled peer=\{msg.source_id} local=\{local_addr} remote=\{effective_addr} protocol=\{transport.protocol()} new=\{is_new_connection}",
  )
  // let now = @env.now()
  // let diff = if now >= conn.last_seen { now - conn.last_seen } else { 0UL }

  // Store peer's public key if provided and compute shared secret (only if not already stored)
  if msg.public_key is Some(pk) {
    compute_and_store_shared_secret(msg.source_id, pk)
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
      relay_message(transport, id, msg, target_peer_id)
    }
  }

  // Handle broadcast forwarding: if broadcast is true, forward to all peers (except sender)
  if msg.broadcast &&
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
    log_info("Received \{msg.kind} from \{msg.source_id} (\{pk_status})")
  }
  match msg {
    { kind: "hello", peers: advertised_peers, .. } => {
      // Logic for hello with optional public_key and secret validation
      let mut secret_matched = false
      let secret_valid = match global_config.val {
        Some(config) => {
          let our_secret_hash = hash_secret(config.secret)
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
          update_global_peer_manager(fn(manager) { manager.add_peer(peer_node) })
        }
        Some(existing) =>
          // Update public key if we found one and existing has none/empty
          if existing.public_key.length() == 0 &&
            effective_pk_opt.unwrap_or(b"").length() > 0 {
            let updated_peer = {
              ..existing,
              public_key: effective_pk_opt.unwrap_or(b""),
            }
            update_global_peer_manager(fn(manager) {
              manager.add_peer(updated_peer)
            })
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

      // Discover peers from advertised peer addresses in hello
      // Instead of waiting for welcome, process advertised peers directly
      if advertised_peers is Some(peer_addrs) {
        let all_conns = get_global_connection_manager().get_all_connections()
        for peer_addr_obj in peer_addrs {
          let peer_url = peer_addr_obj.address
          if !is_bind_all_address(peer_url) && peer_url != local_addr {
            // Track this peer address for active connection attempts
            add_known_peer(peer_url)

            // Check if we already have a relay path for this address
            match get_relay_path(peer_url) {
              Some(_) =>
                // Already greeted this address, skip to avoid duplicate hellos
                ()
              None => {
                // First time seeing this address - set relay path and send hello
                set_relay_path(peer_url, "unknown", msg.source_id)

                // Check if we already have ANY connection to this address (active or not)
                let already_connected = all_conns.any(conn => conn.remote_addr ==
                  peer_url)
                if !already_connected {
                  // Send hello to discover this peer via relay through msg.from
                  let our_addresses = get_our_addresses(local_addr)
                  let session_id = @uuidm.v4_with_rng(
                    @uuidm.SimpleRng::new(@env.now().reinterpret_as_int64()),
                  ).to_string_simple()
                  let hello_msg = create_hello_message(
                    id,
                    local_addr,
                    1,
                    peers=our_addresses,
                    session_id~,
                  )
                  // Send to both direct and relay addresses (fire and forget)
                  send_message_with_fallback(
                    transport, peer_url, sender_addr, hello_msg,
                  )
                  log_info(
                    "Sent hello to discovered peer at \{peer_url} (fallback: \{sender_addr})",
                  )
                }
              }
            }
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
        for peer_url in known_peers {
          // Don't send back to the peer we just received it from
          // Also skip 0.0.0.0 addresses (bind-all, not connectable)
          if peer_url != sender_addr && !is_bind_all_address(peer_url) {
            ignore(send_message(transport, peer_url, msg))
          }
        }
      }
    }
    { kind: "ping", .. } => {
      let reply = Message::new(
        kind="pong",
        source_id=id,
        source_addr=local_addr,
        session_id?=msg.session_id,
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
        if conn.remote_addr == sender_addr {
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
            let timestamp = @env.now()
            manager.update_connection_last_seen(conn.id, timestamp)
          })
        }
      }
    }
    // Proxy handlers moved to kind="data" with ProxyMessage
    { kind: "send", target_id: Some(target), body, .. } => {
      // When sending new data, encrypt it for the target
      let encrypted_data = match body {
        Binary(raw) => @msgpack.binary(encrypt_for_peer(target, raw))
        _ => body // Should be binary
      }
      let direct = Message::new(
        kind="data",
        source_id=msg.source_id,
        source_addr?=msg.source_addr,
        body=encrypted_data,
        target_id=target,
        encrypted=true,
      )
      add_pending_message(direct)
    }
    { kind: "data", body, .. } =>
      handle_data_message(root, id, local_addr, msg, body)
    { kind: "data_response", body: response_data, payload: correlation_id, .. } => {
      let merged = { ..msg, kind: "data", payload: correlation_id }
      handle_data_message(root, id, local_addr, merged, response_data)
    }
    { kind: "sync", body: Array(conn_entries), .. } => {
      // Handle connection update from peer
      // Collect direct neighbors of the sender to update their connections list
      let sender_connections : Array[PeerConnectionInfo] = []

      // Parse connection entry: [peer_id, remote_addr, relay, public_key, latency, bandwidth, packet_loss]
      for entry in conn_entries {
        match Connection::from_msgpack(entry) {
          Some(conn) => {
            let peer_id = conn.peer_id
            let remote_addr = conn.remote_addr
            let relay_depth = conn.relay
            let pk = conn.public_key

            // If relay_depth is 1, it's a direct neighbor of the sender
            if relay_depth == 1 && peer_id != msg.source_id {
              sender_connections.push(PeerConnectionInfo::{
                peer_id,
                latency_ms: conn.latency_ms,
                bandwidth_mbps: conn.bandwidth_mbps,
                packet_loss_rate: conn.packet_loss_rate,
                id: conn.id,
                local_addr: conn.local_addr,
                remote_addr: conn.remote_addr,
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
              update_global_peer_manager(fn(manager) {
                manager.update_route(peer_id, msg.source_id, new_hops)
              })

              // Add discovered address to known peers for potential direct connection
              if remote_addr != "routed" && !is_bind_all_address(remote_addr) {
                add_known_peer(remote_addr)
              }

              // Also compute shared secret if we have the PK
              compute_and_store_shared_secret(peer_id, pk)

              // Ensure peer exists in manager (even if only known via route)
              match get_global_peer_manager().get_peer(peer_id) {
                None => {
                  let addresses = if remote_addr != "routed" &&
                    !is_bind_all_address(remote_addr) {
                    [remote_addr]
                  } else {
                    []
                  }
                  let peer_node = PeerNode::new(
                    id=peer_id,
                    version=conn.version,
                    public_key=pk,
                    addresses~,
                    metadata={},
                  )
                  update_global_peer_manager(fn(manager) {
                    manager.add_peer(peer_node)
                  })
                }
                Some(_) =>
                  // If we have a valid address, add it
                  if remote_addr != "routed" &&
                    !is_bind_all_address(remote_addr) {
                    update_global_peer_manager(fn(manager) {
                      manager.add_peer_address(peer_id, remote_addr)
                    })
                  }
              }

              // Create or update connection if it's a direct neighbor (for compatibility)
              // Only if remote_addr is not "routed" placeholder
              if peer_id == msg.source_id && remote_addr != "routed" {
                // Ensure remote_addr has protocol
                let safe_remote_addr = if remote_addr.contains("://") {
                  remote_addr
                } else {
                  conn.protocol + "://" + remote_addr
                }
                let (_conn, _is_new, _is_new_peer) = handle_new_connection(
                  peer_id,
                  local_addr,
                  safe_remote_addr,
                  conn.protocol,
                  relay_depth~,
                )

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
      root.spawn_bg(fn() {
        handle_incoming_message(
          bytes, sender, my_id, local_addr, root, transport,
        )
      })
    },
    fn(remote_addr) {
      let remote_addr = transport.protocol() + "://" + remote_addr
      let all_conns = get_global_connection_manager().get_all_connections()
      for conn in all_conns {
        if conn.remote_addr == remote_addr {
          update_global_connection_manager(fn(manager) {
            manager.remove_connection(conn.id)
          })
          log_warn("[disconnect]\t\{conn.peer_id}(\{remote_addr})")
          // println("Marked connection \{conn.id} as Disconnected")
        }
      }
    },
  )
}
