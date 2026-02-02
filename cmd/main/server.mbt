///|
fn handle_new_connection(
  peer_id : String,
  local_addr : String,
  remote_addr : String,
  peer_info? : NetworkDiscoveryInfo,
  relay_depth? : Int = 1,
) -> Connection {
  // Get the actual peer ID (from peer_info if available, otherwise from peer_id parameter)
  let actual_peer_id = if peer_info is Some(info) { info.id } else { peer_id }

  // Add or update peer with provided info
  if peer_info is Some(info) {
    let peer_node = PeerNode::new(
      id=info.id,
      version=info.version,
      public_key=info.public_key,
    )
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

  // Add new connection with relay depth
  update_global_peer_manager(fn(manager) {
    let mgr = manager.add_connection(actual_peer_id, local_addr, remote_addr)
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
async fn execute_script_with_output(
  script_name : String,
  command : String,
  input_data : String,
) -> String {
  // Get platform-specific shell
  let (shell, arg) = get_shell()

  // Create a shell command that echoes input data and pipes to the script command
  // This allows passing data to the script and capturing its output
  let full_command = if shell == "cmd.exe" {
    // Windows: use echo | command syntax
    "echo \{input_data} | \{command}"
  } else {
    // Unix/Linux: use echo | command syntax
    "echo '\{input_data}' | \{command}"
  }

  // Execute and capture output (best effort with available tools)
  let exit_code = @process.run(shell, [arg, full_command])
  if exit_code == 0 {
    println("Script \{script_name} executed successfully with input")
    // Return a success indicator
    "Script executed successfully"
  } else {
    println("Script \{script_name} failed with exit code: \{exit_code}")
    "Script execution failed"
  }
}

///|
fn get_best_connection_for_peer(peer_id : String) -> Connection? {
  // Use the intelligent connection selection that prefers direct connections
  get_global_peer_manager().connection_manager.get_best_direct_connection(
    peer_id,
  )
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
    let msgpack_bytes = msg.to_msgpack()
    server.sendto(msgpack_bytes, addr)
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
  // Get our public key for key exchange
  let our_public_key = match get_public_key() {
    Some(key) => Some(serialize_public_key(key))
    None => None
  }
  // Get secret hash for authentication
  let our_secret_hash = match global_config.val {
    Some(config) => Some(hash_secret(config.secret))
    None => None
  }

  // Collect all our bind addresses to spread in discovery
  let our_addresses : Array[NetworkAddress] = match global_config.val {
    Some(config) => {
      let addrs : Array[NetworkAddress] = []
      for listener_url in config.listeners {
        let addr_str = listener_url.get_host()
        addrs.push(NetworkAddress::{ address: addr_str })
      }
      addrs
    }
    None => {
      let addrs : Array[NetworkAddress] = []
      addrs.push(NetworkAddress::{ address: local_addr })
      addrs
    }
  }
  let hello_msg = Message::new(
    kind="hello",
    from=node_id,
    addr=local_addr,
    version=Some(VERSION),
    peers=if our_addresses.is_empty() { None } else { Some(our_addresses) },
    public_key=our_public_key,
    secret_hash=our_secret_hash,
  )
  for {
    // Sleep for 5 seconds between retry checks
    @async.sleep(5000)

    // Retry configured peers that have no active connections
    match global_config.val {
      Some(config) =>
        for peer_url in config.peers {
          let peer_host = peer_url.get_host()
          // Check if any connection to this address is active
          let has_active = get_global_peer_manager().has_active_connection_to_addr(
            peer_host,
          )
          if !has_active {
            let success = send_message(server, peer_host, hello_msg)
            if success {
              println("Retry hello sent to config peer at \{peer_host}")
            }
          }
        }
      None => ()
    }

    // Retry known peers that have lost their connections
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

          // Get all connection addresses for this peer and send hello to each
          let peer_conns = get_global_peer_manager().get_peer_connections(
            peer_id,
          )
          if peer_conns.is_empty() {
            // No known addresses for this peer, skip
            println(
              "No known addresses for peer \{peer_id}, skipping reconnection",
            )
          } else {
            // Send hello to all known addresses for this peer
            let mut sent_any = false
            for conn in peer_conns {
              let peer_addr = conn.remote_addr
              // Skip 0.0.0.0 addresses (bind-all, not connectable)
              if !peer_addr.has_prefix("0.0.0.0:") {
                let success = send_message(server, peer_addr, hello_msg)
                if success {
                  println(
                    "Reconnection hello sent to \{peer_id} at \{peer_addr}",
                  )
                  sent_any = true
                } else {
                  println("Failed to send reconnection hello to \{peer_addr}")
                }
              }
            }
            if sent_any {
              // Reset retry counter on successful send
              update_global_reconnect_manager(fn(manager) {
                manager.reset_retry(peer_id)
              })
              println("Reconnection attempt succeeded for \{peer_id}")
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
          }
        }
      }
    }

    // Also actively try to connect to ALL known peer addresses (configured + discovered)
    let known_peers = get_all_known_peers()
    for peer_addr in known_peers {
      // Check if we already have an active connection to this address
      let has_active = get_global_peer_manager().has_active_connection_to_addr(
        peer_addr,
      )
      if !has_active {
        // Check if this peer has a relay path (discovered through gossip)
        match get_relay_path(peer_addr) {
          Some((_, relay_via_peer_id)) => {
            // This peer was discovered via relay - find active connection to the relay peer
            let relay_conns = get_global_peer_manager().get_active_peer_connections(
              relay_via_peer_id,
            )
            if !relay_conns.is_empty() {
              // Send hello as relayed message through this peer (relay=2 because going through 1 intermediary)
              let relayed_hello = Message::new(
                kind="hello",
                from=node_id,
                addr=local_addr,
                relay=2,
                target=Some(peer_addr),
                version=Some(VERSION),
                public_key=our_public_key,
                secret_hash=our_secret_hash,
              )
              let relay_addr = relay_conns[0].remote_addr
              ignore(send_message(server, relay_addr, relayed_hello))
              println(
                "Sending relayed hello to discovered peer at \{peer_addr} via \{relay_via_peer_id}",
              )
            }
          }
          None => {
            // No relay path (configured peer) - try direct connection first
            let success = send_message(server, peer_addr, hello_msg)
            if success {
              println("Discovered peer at \{peer_addr}")
            } else {
              // Direct connection failed (UDP send failed) - try relaying through intermediaries
              println(
                "Direct connection failed to \{peer_addr}, attempting relay fallback",
              )
              let all_peers = get_global_peer_manager().get_all_peers()

              // Try to relay through all active peers (can't know which relay will work)
              for relay_peer in all_peers {
                let active_conns = get_global_peer_manager().get_active_peer_connections(
                  relay_peer.id,
                )
                if !active_conns.is_empty() {
                  // This peer has active connections
                  let relay_addr = active_conns[0].remote_addr

                  // Create a relayed hello message (relay=2 because going through 1 intermediary)
                  let relayed_hello = Message::new(
                    kind="hello",
                    from=node_id,
                    addr=local_addr,
                    relay=2,
                    target=Some(peer_addr),
                    version=Some(VERSION),
                    public_key=our_public_key,
                    secret_hash=our_secret_hash,
                  )

                  // Send the relayed message to the intermediary
                  ignore(send_message(server, relay_addr, relayed_hello))
                  println(
                    "Attempted fallback relay of hello to \{peer_addr} via \{relay_peer.id}",
                  )
                }
              }
            }
          }
        }
      }
    }
  }
}

///|
async fn handle_pending_messages(
  server : @socket.UdpServer,
  node_id : String,
  root : @async.TaskGroup[Unit],
) -> Unit {
  for {
    // Check for pending messages every 100ms
    @async.sleep(100)
    let pending = get_pending_messages()

    // Process each pending message
    for pending_msg in pending {
      let target = pending_msg.target
      let msg = pending_msg.msg

      // Check if message is for self
      if target == node_id {
        // Handle message to self directly
        match msg.data {
          Some(script_name) => {
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
            println("Processed self-message for \{target}: \{script_name}")
          }
          None => println("Self-message has no data")
        }
      } else {
        // Try to find and send to remote peer
        let target_peer = get_global_peer_manager().get_peer(target)
        match target_peer {
          Some(_) =>
            // Get best connection for target peer
            match get_best_connection_for_peer(target) {
              Some(conn) =>
                // Check if this connection requires relay (relay > 1)
                if conn.relay > 1 {
                  // This peer is only reachable via relay
                  // Find the relay intermediary from relay paths
                  match get_relay_path(conn.remote_addr) {
                    Some((_, relay_via_peer_id)) => {
                      // Find a direct connection to the relay peer
                      let relay_conns = get_global_peer_manager().get_active_peer_connections(
                        relay_via_peer_id,
                      )
                      if !relay_conns.is_empty() {
                        // Send message as relay through the intermediary (relay=2 because going through 1 intermediary)
                        let relayed_msg = Message::new(
                          kind="data",
                          from=msg.from,
                          addr=msg.addr,
                          relay=2,
                          target=Some(conn.remote_addr), // Route to target's address
                          data=msg.data,
                          version=msg.version,
                        )
                        let relay_addr = relay_conns[0].remote_addr
                        ignore(send_message(server, relay_addr, relayed_msg))
                        println(
                          "Sent relayed data to \{target} via \{relay_via_peer_id} at \{relay_addr}",
                        )
                      } else {
                        println(
                          "No active connection to relay peer \{relay_via_peer_id} for target \{target}",
                        )
                      }
                    }
                    None =>
                      println(
                        "No relay path found for relay connection to \{target}",
                      )
                  }
                } else {
                  // Direct connection, send normally
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
        // Record ping time before sending
        update_global_peer_manager(fn(manager) {
          manager.update_connection_ping_time(conn.id, Some(current_time))
        })
        // Increment packets_sent counter
        update_global_peer_manager(fn(manager) {
          manager.update_connection_packet_loss(conn.id, 1, 0)
        })
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
  // Initialize X25519 key pair if not already done
  if global_keypair.val is None {
    init_keypair()
  }

  // Get our public key for key exchange
  let our_public_key = match get_public_key() {
    Some(key) => Some(serialize_public_key(key))
    None => None
  }
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
        // Add configured peers to known peers list for active connection attempts
        add_known_peer(peer_host)
      }
      let secret_hash = Some(hash_secret(config.secret))
      let hello = Message::new(
        kind="hello",
        from=id,
        addr=local_addr,
        version=Some(VERSION),
        peers=Some(peer_addresses),
        public_key=our_public_key,
        secret_hash~,
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
  root.spawn_bg(fn() { handle_pending_messages(server, id, root) })
  for {
    let buf = FixedArray::make(8192, b'0')
    let (n, sender) = server.recvfrom(buf)
    let bytes = buf.unsafe_reinterpret_as_bytes()[0:n].to_bytes()
    let msgpack_value = @msgpack.decode(bytes) catch {
      e => {
        let error_msg = e.to_string()
        println(
          "DEBUG: Msgpack decode error - \{error_msg}, sender: \{sender}, bytes: \{bytes.length()}",
        )
        // Log first 20 bytes for debugging
        if bytes.length() > 0 {
          let preview_len = bytes.length().min(20)
          let preview = bytes[:preview_len]
          println(
            "DEBUG: Message preview (first \{preview_len} bytes): \{bytes_to_hex(preview.to_bytes())}",
          )
        }
        continue
      }
    }
    let msg : Message = Message::from_msgpack(msgpack_value) catch {
      _ => {
        println(
          "Failed to decode message: \{msgpack_value.to_json().stringify()}",
        )
        continue
      }
    }
    // println("Received message: \{msg}")
    println("\{msg.from}(\{sender}): \{msg.kind}")
    let sender_addr = "\{sender}"
    let local_addr = "\{server.addr()}"

    // Skip messages from self
    if msg.from == id {
      continue
    }

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
          public_key: msg.public_key,
        })
      _ => None
    }

    // Always handle connection, even if peer_info is None
    // Connection relay is determined by relay_path (if discovered) or default to 1 (direct)
    let relay_depth_to_use = match get_relay_path(sender_addr) {
      Some(_) => 2 // Has relay path - this connection goes through relay
      None => 1 // No relay path - direct connection
    }
    let conn = handle_new_connection(
      msg.from,
      local_addr,
      sender_addr,
      peer_info?,
      relay_depth=relay_depth_to_use,
    )

    // Store peer's public key if provided and compute shared secret (only if not already stored)
    if msg.public_key is Some(pk) {
      let peer_manager = get_global_peer_manager()
      let peer_already_has_key = match peer_manager.get_peer(msg.from) {
        Some(peer) => peer.public_key is Some(_)
        None => false
      }
      // Only store if we don't already have a public key for this peer
      if !peer_already_has_key {
        update_global_peer_manager(fn(manager) {
          manager.update_peer_public_key(msg.from, pk)
        })
        // Compute and store shared secret for E2E encryption
        match deserialize_public_key(pk) {
          Some(peer_pub_key) =>
            compute_and_store_shared_secret(msg.from, peer_pub_key)
          None =>
            println(
              "Failed to deserialize public key from peer \{msg.from}, raw=\{pk}",
            )
        }
        println("Stored public key for peer \{msg.from}")
      }
    }

    // Track bytes received
    update_global_peer_manager(fn(manager) {
      manager.update_connection_bytes(conn.id, 0UL, n.to_uint64())
    })

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

    // Handle message relaying: if target is set and we're not the target, forward it
    if msg.target is Some(target_addr) {
      // This is a relayed message, forward it to the target with incremented relay depth
      let relay_msg = Message::new(
        id=msg.id,
        kind=msg.kind,
        from=msg.from,
        addr=msg.addr,
        relay=msg.relay + 1,
        version=msg.version,
        peers=msg.peers,
        payload=msg.payload,
        target=msg.target,
        data=msg.data,
        public_key=msg.public_key,
        secret_hash=msg.secret_hash,
        encrypted=msg.encrypted,
      )
      let relay_success = send_message(server, target_addr, relay_msg)
      if relay_success {
        println(
          "Relayed \{msg.kind} from \{msg.from} to \{target_addr} (relay hop \{relay_msg.relay})",
        )
      } else {
        println(
          "Failed to relay \{msg.kind} from \{msg.from} to \{target_addr}",
        )
      }
      // Continue processing this message locally as well (don't return)
    }
    match msg {
      {
        kind: "hello",
        secret_hash: Some(peer_secret_hash),
        peers: advertised_peers,
        ..,
      } => {
        // Learn that this peer can be reached at sender_addr (the address they contacted us from)
        learn_peer_address(msg.from, sender_addr)

        // Add all advertised peer addresses to our discovery list
        if advertised_peers is Some(peer_addrs) {
          for peer_addr in peer_addrs {
            add_known_peer(peer_addr.address)
          }
        }
        // Validate secret before responding
        match global_config.val {
          Some(config) => {
            let our_secret_hash = hash_secret(config.secret)
            if peer_secret_hash != our_secret_hash {
              // Secret mismatch - reject this peer
              println(
                "Rejecting peer \{msg.from} at \{sender_addr}: secret mismatch",
              )
              () // Don't send welcome
            } else {
              // Secret matches - send welcome with known peers and learned addresses (gossip)
              let welcome_peer_addresses : Array[NetworkAddress] = []
              let all_peers = get_global_peer_manager().get_all_peers()
              let all_conns = get_global_peer_manager().get_all_connections()

              // Include all learned addresses for each peer (gossip protocol) - deduplicated
              for peer in all_peers {
                let learned_addrs = get_learned_addresses(peer.id)
                for learned_addr in learned_addrs {
                  // Don't include the sender in our peer list to avoid loops
                  if learned_addr != sender_addr {
                    // Only add if not already in the list (deduplicate)
                    let not_already_included = !welcome_peer_addresses.any(fn(
                      np,
                    ) {
                      np.address == learned_addr
                    })
                    if not_already_included {
                      welcome_peer_addresses.push(NetworkAddress::{
                        address: learned_addr,
                      })
                    }
                  }
                }
              }

              // Also include connection addresses from peers we're connected to
              for peer in all_peers {
                // Get connection addresses for this peer
                let peer_conns = peer.get_all_connections(all_conns)
                for conn in peer_conns {
                  // Don't include the sender in our peer list to avoid loops
                  if conn.remote_addr != sender_addr {
                    // Check if not already in learned addresses
                    let not_already_included = !welcome_peer_addresses.any(fn(
                      np,
                    ) {
                      np.address == conn.remote_addr
                    })
                    if not_already_included {
                      welcome_peer_addresses.push(NetworkAddress::{
                        address: conn.remote_addr,
                      })
                      println(
                        "DEBUG: Adding connection address for peer \{peer.id}: \{conn.remote_addr}",
                      )
                    }
                  }
                }
              }

              // Also include configured peers to help with initial discovery
              for peer_url in config.peers {
                let peer_addr = peer_url.get_host()
                // Avoid duplicates and self
                let not_already_included = !welcome_peer_addresses.any(fn(np) {
                  np.address == peer_addr
                })
                if not_already_included &&
                  peer_addr != sender_addr &&
                  peer_addr != local_addr {
                  welcome_peer_addresses.push(NetworkAddress::{
                    address: peer_addr,
                  })
                  println("DEBUG: Adding configured peer: \{peer_addr}")
                }
              }
              let reply = Message::new(
                kind="welcome",
                from=id,
                addr=local_addr,
                peers=Some(welcome_peer_addresses),
                public_key=our_public_key,
                secret_hash=Some(our_secret_hash),
              )
              ignore(send_message(server, sender_addr, reply))
              let addr_list = if welcome_peer_addresses.is_empty() {
                "none"
              } else {
                welcome_peer_addresses.map(fn(na) { na.address }).join(", ")
              }
              println(
                "Accepted peer \{msg.from} at \{sender_addr} - sent welcome with \{welcome_peer_addresses.length()} addresses: [\{addr_list}]",
              )
            }
          }
          None => {
            // No config - accept hello but send minimal welcome
            let welcome_peer_addresses : Array[NetworkAddress] = []
            let all_peers = get_global_peer_manager().get_all_peers()
            let all_conns = get_global_peer_manager().get_all_connections()

            // Include learned addresses
            for peer in all_peers {
              let learned_addrs = get_learned_addresses(peer.id)
              for learned_addr in learned_addrs {
                if learned_addr != sender_addr {
                  welcome_peer_addresses.push(NetworkAddress::{
                    address: learned_addr,
                  })
                }
              }
            }

            // Include connection addresses
            for peer in all_peers {
              let peer_conns = peer.get_all_connections(all_conns)
              for conn in peer_conns {
                if conn.remote_addr != sender_addr {
                  // Check if not already in learned addresses
                  let not_already_included = !welcome_peer_addresses.any(fn(
                    np,
                  ) {
                    np.address == conn.remote_addr
                  })
                  if not_already_included {
                    welcome_peer_addresses.push(NetworkAddress::{
                      address: conn.remote_addr,
                    })
                  }
                }
              }
            }
            let reply = Message::new(
              kind="welcome",
              from=id,
              addr=local_addr,
              peers=Some(welcome_peer_addresses),
              public_key=our_public_key,
            )
            ignore(send_message(server, sender_addr, reply))
          }
        }
      }
      { kind: "hello", .. } => {
        // Hello without secret_hash - reject it (backwards compatibility)
        println("Rejecting hello from \{msg.from}: no secret_hash provided")
        ()
      }
      { kind: "welcome", peers: Some(peers), .. } => {
        // Learn that this peer can be reached at sender_addr
        learn_peer_address(msg.from, sender_addr)

        // Store the welcome sender's public key if provided (only if not already stored)
        if msg.public_key is Some(pk) {
          let peer_manager = get_global_peer_manager()
          let peer_already_has_key = match peer_manager.get_peer(msg.from) {
            Some(peer) => peer.public_key is Some(_)
            None => false
          }
          if !peer_already_has_key {
            update_global_peer_manager(fn(manager) {
              manager.update_peer_public_key(msg.from, pk)
            })
            println(
              "Stored public key for peer \{msg.from} from welcome message",
            )
          }
        }

        // Welcome message - discover new peers from the list
        // These peers are discovered through a relay (the sender of this welcome message)
        // Send hello to each peer address, let their response bring us the actual peer ID
        let all_conns = get_global_peer_manager().get_all_connections()
        for peer_addr_obj in peers {
          let peer_addr = peer_addr_obj.address
          // Skip 0.0.0.0 addresses (bind-all, not connectable) and our own address
          if !peer_addr.has_prefix("0.0.0.0:") && peer_addr != local_addr {
            // Track this peer address for active connection attempts
            add_known_peer(peer_addr)

            // Check if we already have a relay path for this address
            // If so, we've already sent a hello to it before
            match get_relay_path(peer_addr) {
              Some(_) =>
                // Already greeted this address, skip to avoid duplicate hellos
                ()
              None => {
                // First time seeing this address - set relay path and send hello
                set_relay_path(peer_addr, "unknown", msg.from)

                // Check if we already have ANY connection to this address (active or not)
                let already_connected = all_conns.any(fn(conn) {
                  conn.remote_addr == peer_addr
                })
                if !already_connected {
                  // Send hello to discover this peer via relay through msg.from
                  // The hello response will bring us the actual peer ID
                  let our_secret_hash = match global_config.val {
                    Some(config) => Some(hash_secret(config.secret))
                    None => None
                  }
                  let hello_msg = Message::new(
                    kind="hello",
                    from=id,
                    addr=local_addr,
                    version=Some(VERSION),
                    public_key=our_public_key,
                    secret_hash=our_secret_hash,
                    target=Some(peer_addr),
                  )
                  // Send the relayed hello through the peer that advertised it
                  let relay_addr = sender_addr
                  ignore(send_message(server, relay_addr, hello_msg))
                  println(
                    "Greeting discovered peer at \{peer_addr} via relay through \{msg.from}",
                  )
                }
              }
            }
          }
        }
      }
      { kind: "welcome", .. } => {
        // Welcome message without peer list - but may still have public_key
        // Learn that this peer can be reached at sender_addr
        learn_peer_address(msg.from, sender_addr)
        if msg.public_key is Some(pk) {
          let peer_manager = get_global_peer_manager()
          let peer_already_has_key = match peer_manager.get_peer(msg.from) {
            Some(peer) => peer.public_key is Some(_)
            None => false
          }
          if !peer_already_has_key {
            update_global_peer_manager(fn(manager) {
              manager.update_peer_public_key(msg.from, pk)
            })
            println(
              "Stored public key for peer \{msg.from} from welcome message",
            )
          }
        }
      }
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
            let current_time = @env.now()
            // Calculate RTT if we have a ping timestamp
            match conn.last_ping_time {
              Some(ping_time) => {
                let rtt_ms = (current_time - ping_time).to_int()
                update_global_peer_manager(fn(manager) {
                  manager.update_connection_latency(conn.id, rtt_ms)
                })
              }
              None => ()
            }
            update_global_peer_manager(fn(manager) {
              let timestamp = @env.now()
              manager.update_connection_last_seen(conn.id, timestamp)
            })
          }
        }
      }
      { kind: "punch_request", target: Some(target), .. } => {
        let punch_to_target = Message::new(
          kind="punch",
          from=id,
          addr=local_addr,
          relay=2,
          target=Some(sender_addr),
        )
        let punch_to_sender = Message::new(
          kind="punch",
          from=id,
          addr=local_addr,
          relay=2,
          target=Some(target),
        )
        ignore(send_message(server, target, punch_to_target))
        ignore(send_message(server, sender_addr, punch_to_sender))
      }
      { kind: "punch", target: Some(target), .. } => {
        let ack_to_target = Message::new(
          kind="punch_ack",
          from=id,
          addr=local_addr,
        )
        let ack_to_sender = Message::new(
          kind="punch_ack",
          from=id,
          addr=local_addr,
        )
        ignore(send_message(server, target, ack_to_target))
        ignore(send_message(server, sender_addr, ack_to_sender))
      }
      { kind: "relay", target: Some(target), data: Some(data), .. } => {
        let forward = Message::new(
          kind="data",
          from=msg.from,
          addr=msg.addr,
          relay=2,
          data=Some(data),
          target=Some(target),
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
              relay=2,
              target=Some(target),
            )
            let relay = Message::new(
              kind="relay",
              from=msg.from,
              addr=msg.addr,
              relay=2,
              target=Some(target),
              data=Some(data),
            )
            ignore(send_message(server, relay_conn.remote_addr, request))
            ignore(send_message(server, relay_conn.remote_addr, relay))
          }
          None => ()
        }
      }
      { kind: "data", data: Some(raw_data), encrypted, .. } => {
        // Decrypt data if encrypted
        let data_content = if encrypted {
          match decrypt_message_from_peer(msg.from, raw_data) {
            Some(decrypted) => decrypted
            None => {
              println(
                "Failed to decrypt message from \{msg.from}, raw=\{raw_data}",
              )
              raw_data // Fall back to raw data if decryption fails
            }
          }
        } else {
          raw_data
        }

        // Execute scripts with received data and send back output
        root.spawn_bg(fn() {
          match global_config.val {
            Some(config) =>
              match config.scripts {
                Some(scripts) => {
                  // Collect script outputs
                  let script_outputs : Array[String] = []
                  for script_name, command in scripts {
                    let output = execute_script_with_output(
                      script_name, command, data_content,
                    )
                    script_outputs.push("\{script_name}: \{output}")
                    println("Executed script \{script_name} with received data")
                  }
                  // Send response back to sender with script outputs
                  let response_msg = Message::new(
                    kind="data_response",
                    from=id,
                    addr=local_addr,
                    relay=1,
                    data=Some(script_outputs.join("\n")),
                  )
                  ignore(send_message(server, msg.from, response_msg))
                }
                None =>
                  println(
                    "No scripts configured, received data: \{data_content}",
                  )
              }
            None => println("Config not available")
          }
        })
      }
      { kind: "data_response", data: Some(response_data), .. } => {
        // Handle response from script execution
        println("Received script response from \{msg.from}:")
        println(response_data)
      }
      _ => ()
    }
    root.spawn_bg(fn() {  })
  }
}
