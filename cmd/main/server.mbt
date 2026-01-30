///|
fn handle_new_connection(
  peer_id : String,
  local_addr : String,
  remote_addr : String,
  peer_info? : NetworkDiscoveryInfo,
) -> Connection {
  // Get the actual peer ID (from peer_info if available, otherwise from peer_id parameter)
  let actual_peer_id = if peer_info is Some(info) { info.id } else { peer_id }

  // Add or update peer with provided info
  if peer_info is Some(info) {
    let peer_node = PeerNode::new(id=info.id, version=info.version)
    update_global_peer_manager(fn(manager) { manager.add_peer(peer_node) })
  } else {
    // Only create peer if it doesn't exist yet
    match get_global_peer_manager().get_peer(actual_peer_id) {
      Some(_) => () // Peer exists, don't override
      None => {
        let peer_node = PeerNode::new(id=actual_peer_id, version=VERSION)
        update_global_peer_manager(fn(manager) { manager.add_peer(peer_node) })
      }
    }
  }

  // Check if connection already exists
  let existing_conns = get_global_peer_manager().get_peer_connections(
    actual_peer_id,
  )
  for existing_conn in existing_conns {
    if existing_conn.local_addr == local_addr &&
      existing_conn.remote_addr == remote_addr {
      // Connection already exists, return it
      return existing_conn
    }
  }

  // Add new connection
  update_global_peer_manager(fn(manager) {
    manager.add_connection(actual_peer_id, local_addr, remote_addr)
  })
  // Get the connection we just added
  let conns = get_global_peer_manager().get_peer_connections(actual_peer_id)
  let filtered = conns.filter(fn(c) {
    c.local_addr == local_addr && c.remote_addr == remote_addr
  })
  if filtered.is_empty() {
    conns[0]
  } else {
    filtered[0]
  }
}

///|
#cfg(platform="windows")
fn get_shell() -> (String, String) {
  ("cmd.exe", "/c")
}

///|
#cfg(not(platform="windows"))
fn get_shell() -> (String, String) {
  ("sh", "-c")
}

///|
async fn execute_script(script_name : String, command : String) -> Unit {
  // Get platform-specific shell
  let (shell, arg) = get_shell()

  // Execute the script command using platform-specific shell
  let exit_code = @process.run(shell, [arg, command])
  if exit_code == 0 {
    println("Script \{script_name} executed successfully")
  } else {
    println("Script \{script_name} failed with exit code: \{exit_code}")
  }
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
  let hello_msg = Message::new(
    kind="hello",
    from=node_id,
    addr=local_addr,
    version=Some(VERSION),
  )
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
async fn handle_pending_messages(server : @socket.UdpServer) -> Unit {
  for {
    // Check for pending messages every 100ms
    @async.sleep(100)
    let pending = get_pending_messages()

    // Process each pending message
    for pending_msg in pending {
      let target = pending_msg.target
      let msg = pending_msg.msg

      // Try to find and send to target peer
      let target_peer = get_global_peer_manager().get_peer(target)
      match target_peer {
        Some(_) =>
          // Get best connection for target peer
          match get_best_connection_for_peer(target) {
            Some(conn) => {
              ignore(send_message(server, conn.remote_addr, msg))
              println("Sent message to \{target} via \{conn.remote_addr}")
            }
            None => println("No active connection to target \{target}")
          }
        None => println("Target peer \{target} not found")
      }
    }
  }
}

///|
async fn handle_heartbeat(
  server : @socket.UdpServer,
  local_addr : String,
  node_id : String,
) -> Unit {
  let heartbeat_interval = 10000 // 10 seconds
  for {
    @async.sleep(heartbeat_interval)
    let current_time = @env.now()
    let all_peers = get_global_peer_manager().get_all_peers()
    for peer in all_peers {
      let peer_id = peer.id
      let peer_conns = get_global_peer_manager().get_peer_connections(peer_id)

      // Send ping to all connections of this peer
      for conn in peer_conns {
        let ping_msg = Message::new(
          kind="ping",
          from=node_id,
          addr=local_addr,
          version=Some(VERSION),
        )
        ignore(send_message(server, conn.remote_addr, ping_msg))

        // Check if connection has timed out (no response for 30 seconds)
        if current_time - conn.last_seen > 30000UL && conn.is_active() {
          println("Connection to \{peer_id} at \{conn.remote_addr} timed out")
          update_global_peer_manager(fn(manager) {
            manager.update_connection_state(
              conn.id,
              ConnectionState::Disconnected,
            )
          })
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

  // Get peer addresses from config and send hello messages directly
  match global_config.val {
    Some(config) => {
      let peer_addresses : Array[NetworkAddress] = []
      for peer_url in config.peers {
        let peer_host = peer_url.get_host()
        peer_addresses.push(NetworkAddress::{ address: peer_host })
      }
      let hello = Message::new(
        kind="hello",
        from=id,
        addr=local_addr,
        version=Some(VERSION),
        peers=Some(peer_addresses),
      )

      // Send hello to all configured peer addresses from this listener
      for peer_url in config.peers {
        let peer_host = peer_url.get_host()
        ignore(send_message(server, peer_host, hello))
      }
    }
    None => ()
  }

  // Start reconnection background task
  root.spawn_bg(fn() { handle_reconnects(server, local_addr, id) })
  // Start heartbeat/health check background task
  root.spawn_bg(fn() { handle_heartbeat(server, local_addr, id) })
  // Start pending message sender background task
  root.spawn_bg(fn() { handle_pending_messages(server) })
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
    println("Received message: \{msg}")
    // println("Received(\{sender}): \{msg.kind} from \{msg.id}")
    let sender_addr = "\{sender}"
    let local_addr = "\{server.addr()}"

    // Handle the connection - always create/update connection for any message
    let peer_info = match msg.kind {
      "hello" =>
        Some(NetworkDiscoveryInfo::{
          id: msg.from,
          version: match msg.version {
            Some(v) => v
            None => VERSION
          },
          addresses: [NetworkAddress::{ address: sender_addr }], // Use actual sender address
          peers: msg.peers,
        })
      _ => None
    }

    // Always handle connection, even if peer_info is None
    let conn = handle_new_connection(
      msg.from,
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
      // Use current time as timestamp
      let timestamp = @env.now() // Far future to prevent timeout
      manager.update_connection_last_seen(conn.id, timestamp)
    })

    // Don't create peers from peer list - wait for welcome message

    // Don't create peer from sender address - wait for welcome message
    match msg {
      { kind: "hello", .. } => {
        // 发送 welcome 消息，包含已知的peer连接地址
        let welcome_peer_addresses : Array[NetworkAddress] = []
        let all_peers = get_global_peer_manager().get_all_peers()
        let all_conns = get_global_peer_manager().get_all_connections()
        for peer in all_peers {
          // Get connection addresses for this peer
          let peer_conns = peer.get_all_connections(all_conns)
          for conn in peer_conns {
            // Don't include the sender in our peer list to avoid loops
            if conn.remote_addr != sender_addr {
              welcome_peer_addresses.push(NetworkAddress::{
                address: conn.remote_addr,
              })
            }
          }
        }
        let reply = Message::new(
          kind="welcome",
          from=id,
          addr=local_addr,
          peers=Some(welcome_peer_addresses),
        )
        ignore(send_message(server, sender_addr, reply))
      }
      { kind: "welcome", peers: Some(peers), .. } =>
        // Welcome message - discover new peers from the list
        for peer_addr_obj in peers {
          let peer_addr = peer_addr_obj.address

          // Skip 0.0.0.0 addresses (bind-all, not connectable)
          if !peer_addr.has_prefix("0.0.0.0:") {
            // Check if we already know this peer
            match get_global_peer_manager().get_peer(peer_addr) {
              Some(_) => () // Already known
              None => {
                // New peer discovered! Create it and add connection
                let new_peer = PeerNode::new(id=peer_addr, version=VERSION)
                update_global_peer_manager(fn(manager) {
                  manager.add_peer(new_peer)
                })

                // Send hello to the newly discovered peer to establish connection
                let hello_msg = Message::new(
                  kind="hello",
                  from=msg.from,
                  addr=local_addr,
                  version=Some(VERSION),
                )
                ignore(send_message(server, peer_addr, hello_msg))
                println("Discovered and greeting new peer: \{peer_addr}")
              }
            }
          }
        }
      { kind: "welcome", .. } =>
        // Welcome message without peer list
        ()
      { kind: "ping", .. } => {
        let reply = Message::new(kind="pong", from=id, addr=local_addr)
        ignore(send_message(server, sender_addr, reply))
      }
      { kind: "pong", .. } => {
        // Heartbeat response received - mark connection as healthy
        let peer_id = msg.from
        let peer_conns = get_global_peer_manager().get_peer_connections(peer_id)
        // Find the connection that matches this sender and update its last_seen
        for conn in peer_conns {
          if conn.remote_addr == sender_addr {
            update_global_peer_manager(fn(manager) {
              let timestamp = @env.now()
              manager.update_connection_last_seen(conn.id, timestamp)
            })
          }
        }
        println("Received pong from \{peer_id}")
      }
      { kind: "punch_request", target: Some(target), .. } => {
        let punch_to_target = Message::new(
          kind="punch",
          from=id,
          addr=local_addr,
          target=Some(sender_addr),
        )
        let punch_to_sender = Message::new(
          kind="punch",
          from=id,
          addr=local_addr,
          target=Some(target),
        )
        ignore(send_message(server, target, punch_to_target))
        ignore(send_message(server, sender_addr, punch_to_sender))
      }
      { kind: "punch", target: Some(target), .. } => {
        let ack_to_target = Message::new(kind="punch_ack", from=id, addr=local_addr)
        let ack_to_sender = Message::new(kind="punch_ack", from=id, addr=local_addr)
        ignore(send_message(server, target, ack_to_target))
        ignore(send_message(server, sender_addr, ack_to_sender))
      }
      { kind: "relay", target: Some(target), data: Some(data), .. } => {
        let forward = Message::new(
          kind="data",
          from=msg.from,
          addr=msg.addr,
          data=Some(data),
        )
        ignore(send_message(server, target, forward))
      }
      { kind: "send", target: Some(target), data: Some(data), .. } => {
        let direct = Message::new(
          kind="data",
          from=msg.from,
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
              from=id,
              addr=local_addr,
              target=Some(target),
            )
            let relay = Message::new(
              kind="relay",
              from=msg.from,
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
      { kind: "data", data: Some(script_name), .. } =>
        // Check if a script exists with this name and execute it asynchronously
        root.spawn_bg(fn() {
          match global_config.val {
            Some(config) =>
              match config.scripts {
                Some(scripts) =>
                  match scripts.get(script_name) {
                    Some(command) => execute_script(script_name, command)
                    None => println("Script not found: \{script_name}")
                  }
                None => println("No scripts configured")
              }
            None => println("Config not available")
          }
        })
      _ => ()
    }
    root.spawn_bg(fn() {  })
  }
}
