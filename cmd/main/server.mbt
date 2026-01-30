///|
fn handle_new_connection(
  peer_id : String,
  local_addr : String,
  remote_addr : String,
  peer_info? : NetworkDiscoveryInfo,
) -> Connection {
  // Add or update peer - create PeerNode from peer_info or use basic info
  let peer_node = if peer_info is Some(info) {
    PeerNode::new(id=info.id, version=info.version)
  } else {
    PeerNode::new(id=peer_id, version="unknown")
  }
  update_global_peer_manager(fn(manager) { manager.add_peer(peer_node) })

  // Check if connection already exists
  let existing_conns = get_global_peer_manager().get_peer_connections(peer_id)
  for existing_conn in existing_conns {
    if existing_conn.local_addr == local_addr &&
      existing_conn.remote_addr == remote_addr {
      // Connection already exists, return it
      return existing_conn
    }
  }

  // Add new connection
  let conn = get_global_peer_manager().add_connection(
    peer_id, local_addr, remote_addr,
  )
  conn
}

///|
fn get_best_connection_for_peer(peer_id : String) -> Connection? {
  let active_conns = get_global_peer_manager().get_active_peer_connections(
    peer_id,
  )
  if active_conns.is_empty() {
    None
  } else {
    // Return the connection with best quality
    let best = active_conns[0]
    Some(
      active_conns.fold(init=best, fn(best, conn) {
        if conn.quality > best.quality {
          conn
        } else {
          best
        }
      }),
    )
  }
}

///|
async fn send_message(
  server : @socket.UdpServer,
  peer : String,
  msg : Message,
) -> Bool {
  if peer.is_empty() {
    return false
  }
  try {
    let addr = @socket.Addr::parse(peer)
    server.sendto(msg.to_msgpack(), addr)
    true
  } catch {
    _ => {
      println("Failed to send message to \{peer}")
      false
    }
  }
}

///|
async fn handle_reconnects(
  server : @socket.UdpServer,
  local_addr : String,
  node_id : String,
) -> Unit {
  let hello_msg = Message::{
    kind: "hello",
    id: node_id,
    addr: local_addr,
    version: Some(VERSION),
    peers: None,
    payload: None,
    target: None,
    data: None,
  }
  for {
    // Sleep for 5 seconds between retry checks
    @async.sleep(5000)
    let all_peers = get_global_peer_manager().get_all_peers()
    for peer in all_peers {
      let peer_id = peer.id

      // Check if peer has active connections
      let active_conns = get_global_peer_manager().get_active_peer_connections(
        peer_id,
      )
      if active_conns.is_empty() {
        // No active connections, check if we should retry
        if get_global_reconnect_manager().should_retry(peer_id) {
          println("Attempting to reconnect to \{peer_id}")

          // Try to send hello message, but skip invalid addresses
          // Get connection addresses for this peer
          let peer_conns = get_global_peer_manager().get_peer_connections(
            peer_id,
          )
          let peer_addr = if peer_conns.is_empty() {
            peer_id // Fallback to peer ID if no connections
          } else {
            peer_conns[0].remote_addr // Use first connection's remote address
          }
          if !peer_addr.has_prefix("0.0.0.0:") {
            let success = send_message(server, peer_addr, hello_msg)
            if success {
              // Reset retry counter on successful send
              update_global_reconnect_manager(fn(manager) {
                manager.reset_retry(peer_id)
              })
              println("Reconnection attempt sent to \{peer_id}")
            } else {
              // Record failed retry attempt
              update_global_reconnect_manager(fn(manager) {
                manager.record_retry(peer_id)
              })
              let (attempts, next_delay) = get_global_reconnect_manager().get_retry_info(
                peer_id,
              )
              println(
                "Reconnection failed to \{peer_id}, attempt \{attempts}, next retry in \{next_delay}ms",
              )
            }
          } else {
            println("Skipping invalid address \{peer_addr} for peer \{peer_id}")
          }
        }
      }
    }
  }
}

///|
async fn listen_udp(
  root : @async.TaskGroup[Unit],
  addr : @socket.Addr,
  id : String,
) -> Unit {
  let server = @socket.UdpServer::new(addr)
  defer server.close()
  let local_addr = "\{server.addr()}"

  // Don't initialize with peers - peers will be discovered through welcome messages

  // Get all known peers for hello message
  let known_peers = get_global_peer_manager().get_all_peers()
  let peer_addresses : Array[NetworkAddress] = []
  for peer in known_peers {
    // Get connection addresses for this peer
    let peer_conns = get_global_peer_manager().get_peer_connections(peer.id)
    if !peer_conns.is_empty() {
      peer_addresses.push(NetworkAddress::{ address: peer_conns[0].remote_addr })
    } else {
      // If no connections, use peer ID as fallback
      peer_addresses.push(NetworkAddress::{ address: peer.id })
    }
  }
  let hello = Message::{
    kind: "hello",
    id,
    addr: local_addr,
    version: Some(VERSION),
    peers: Some(peer_addresses),
    payload: None,
    target: None,
    data: None,
  }

  // Send hello to all known peers using their connection addresses
  for peer in known_peers {
    let peer_conns = get_global_peer_manager().get_peer_connections(peer.id)
    if !peer_conns.is_empty() {
      ignore(send_message(server, peer_conns[0].remote_addr, hello))
    }
  }

  // Start reconnection background task
  root.spawn_bg(fn() { handle_reconnects(server, local_addr, id) })
  for {
    let buf = FixedArray::make(2048, b'0')
    let (n, sender) = server.recvfrom(buf)
    let bytes = buf.unsafe_reinterpret_as_bytes()[0:n].to_bytes()
    let msg : Message = Message::from_msgpack(@msgpack.decode(bytes)) catch {
      _ => {
        println("Failed to decode message")
        continue
      }
    }
    println("Received(\{sender}): \{msg.kind} from \{msg.id}")
    let sender_addr = "\{sender}"
    let local_addr = "\{server.addr()}"

    // Handle the connection - always create/update connection for any message
    let peer_info = match msg.kind {
      "hello" =>
        Some(NetworkDiscoveryInfo::{
          id: msg.id,
          version: "0.1.0", // Default version
          addresses: [NetworkAddress::{ address: sender_addr }], // Use actual sender address
          peers: msg.peers,
        })
      _ => None
    }

    // Always handle connection, even if peer_info is None
    let conn = handle_new_connection(
      msg.id,
      local_addr,
      sender_addr,
      peer_info?,
    )

    // Update connection state to Connected and update last_seen timestamp
    update_global_peer_manager(fn(manager) {
      let manager = manager.update_connection_state(
        conn.id,
        ConnectionState::Connected,
      )
      // Use current time as timestamp (simplified for now)
      let timestamp = 9999999999999L // Far future to prevent timeout
      manager.update_connection_last_seen(conn.id, timestamp)
    })

    // Don't create peers from peer list - wait for welcome message

    // Don't create peer from sender address - wait for welcome message
    match msg {
      { kind: "hello", .. } => {
        // 发送 welcome 消息，但排除对方的 peers（避免循环）
        let welcome_peer_addresses : Array[NetworkAddress] = []
        let all_peers = get_global_peer_manager().get_all_peers()
        let all_conns = get_global_peer_manager().get_all_connections()
        for peer in all_peers {
          // Get connection addresses for this peer
          let peer_conns = peer.get_all_connections(all_conns)
          for conn in peer_conns {
            if conn.remote_addr != sender_addr {
              welcome_peer_addresses.push(NetworkAddress::{
                address: conn.remote_addr,
              })
            }
          }
        }
        let reply = Message::new(
          kind="welcome",
          id~,
          addr=local_addr,
          peers=Some(welcome_peer_addresses),
        )
        ignore(send_message(server, sender_addr, reply))
      }
      { kind: "ping", .. } => {
        let reply = Message::new(kind="pong", id~, addr=local_addr)
        ignore(send_message(server, sender_addr, reply))
      }
      { kind: "punch_request", target: Some(target), .. } => {
        let punch_to_target = Message::new(
          kind="punch",
          id~,
          addr=local_addr,
          target=Some(sender_addr),
        )
        let punch_to_sender = Message::new(
          kind="punch",
          id~,
          addr=local_addr,
          target=Some(target),
        )
        ignore(send_message(server, target, punch_to_target))
        ignore(send_message(server, sender_addr, punch_to_sender))
      }
      { kind: "punch", target: Some(target), .. } => {
        let ack_to_target = Message::new(kind="punch_ack", id~, addr=local_addr)
        let ack_to_sender = Message::new(kind="punch_ack", id~, addr=local_addr)
        ignore(send_message(server, target, ack_to_target))
        ignore(send_message(server, sender_addr, ack_to_sender))
      }
      { kind: "relay", target: Some(target), data: Some(data), .. } => {
        let forward = Message::new(
          kind="data",
          id=msg.id,
          addr=msg.addr,
          data=Some(data),
        )
        ignore(send_message(server, target, forward))
      }
      { kind: "send", target: Some(target), data: Some(data), .. } => {
        let direct = Message::new(
          kind="data",
          id=msg.id,
          addr=msg.addr,
          data=Some(data),
        )
        ignore(send_message(server, target, direct))
        // Find best relay peer
        let all_peers = get_global_peer_manager().get_all_peers()
        let mut best_relay : Connection? = None
        for peer in all_peers {
          let peer_id = peer.id
          if peer_id != target &&
            peer_id != sender_addr &&
            peer_id != local_addr {
            match get_best_connection_for_peer(peer_id) {
              Some(conn) => {
                best_relay = Some(conn)
                break
              }
              None => ()
            }
          }
        }
        match best_relay {
          Some(relay_conn) => {
            let request = Message::new(
              kind="punch_request",
              id~,
              addr=local_addr,
              target=Some(target),
            )
            let relay = Message::new(
              kind="relay",
              id=msg.id,
              addr=msg.addr,
              target=Some(target),
              data=Some(data),
            )
            ignore(send_message(server, relay_conn.remote_addr, request))
            ignore(send_message(server, relay_conn.remote_addr, relay))
          }
          None => ()
        }
      }
      { kind: "data", data: Some(_), .. } => println("data: \{msg}")
      _ => ()
    }
    root.spawn_bg(fn() {  })
  }
}
