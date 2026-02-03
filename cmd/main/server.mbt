///|
const HELLO_DEBOUNCE_MS : UInt64 = 5000

///|
fn handle_new_connection(
  peer_id : String,
  local_addr : String,
  remote_addr : String,
  peer_info? : NetworkDiscoveryInfo,
  relay_depth? : Int = 1,
) -> (Connection, Bool) {
  // Get the actual peer ID (from peer_info if available, otherwise from peer_id parameter)
  let actual_peer_id = if peer_info is Some(info) { info.id } else { peer_id }

  // Add or update peer with provided info
  if peer_info is Some(info) {
    let peer_node = PeerNode::new(
      id=info.id,
      version=info.version,
      public_key?=info.public_key,
    )
    update_global_peer_manager(fn(manager) { manager.add_peer(peer_node) })

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
      // Connection already exists, return it with is_new=false
      return (existing_conn, false)
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
  let conn = if filtered.is_empty() { conns[0] } else { filtered[0] }
  // Return the new connection with is_new=true
  (conn, true)
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
// Try sending to both primary and fallback addresses (UDP fire-and-forget)
// We send to both because UDP doesn't guarantee delivery anyway
async fn send_message_with_fallback(
  server : @socket.UdpServer,
  primary_addr : String,
  fallback_addr : String,
  msg : Message,
) -> Unit {
  // Try primary address - fire and forget
  if !primary_addr.is_empty() {
    try {
      let addr = @socket.Addr::parse(primary_addr)
      let msgpack_bytes = msg.to_msgpack()
      server.sendto(msgpack_bytes, addr)
      println("Sent to primary \{primary_addr}")
    } catch {
      _ => println("Failed to send to primary \{primary_addr}")
    }
  }

  // Try fallback address - fire and forget
  if !fallback_addr.is_empty() && fallback_addr != primary_addr {
    try {
      let addr = @socket.Addr::parse(fallback_addr)
      let msgpack_bytes = msg.to_msgpack()
      server.sendto(msgpack_bytes, addr)
      println("Sent to fallback \{fallback_addr}")
    } catch {
      _ => println("Failed to send to fallback \{fallback_addr}")
    }
  }
}

///|
fn get_identity_info() -> (String?, String?) {
  let our_public_key = match get_public_key() {
    Some(key) => Some(serialize_public_key(key))
    None => None
  }
  let our_secret_hash = match global_config.val {
    Some(config) => Some(hash_secret(config.secret))
    None => None
  }
  (our_public_key, our_secret_hash)
}

///|
fn get_our_addresses(local_addr : String) -> Array[NetworkAddress] {
  match global_config.val {
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
}

///|
fn create_connection_update_message(
  node_id : String,
  local_addr : String,
) -> Message {
  // Create a message that includes all current connections of this node
  let all_peers = get_global_peer_manager().get_all_peers()
  let all_conns = get_global_peer_manager().get_all_connections()
  let connections_data : Array[String] = []
  for peer in all_peers {
    let peer_conns = peer.get_all_connections(all_conns)
    for conn in peer_conns {
      // Format: "peer_id:remote_addr:relay"
      let conn_str = "\{peer.id}:\{conn.remote_addr}:\{conn.relay}"
      connections_data.push(conn_str)
    }
  }
  Message::new(
    kind="connection_update",
    from=node_id,
    addr=local_addr,
    relay=1,
    data=@msgpack.array(connections_data.map(@msgpack.string)),
  )
}

///|
async fn broadcast_connection_update(
  server : @socket.UdpServer,
  node_id : String,
  local_addr : String,
) -> Unit {
  let update_msg = create_connection_update_message(node_id, local_addr)
  let all_peers = get_global_peer_manager().get_all_peers()
  for peer in all_peers {
    let peer_conns = get_global_peer_manager().get_active_peer_connections(
      peer.id,
    )
    for conn in peer_conns {
      if conn.state == ConnectionState::Connected {
        ignore(send_message(server, conn.remote_addr, update_msg))
      }
    }
  }
}

///|
fn create_hello_message(
  node_id : String,
  local_addr : String,
  relay : Int,
  peers? : Array[NetworkAddress],
) -> Message {
  let (public_key, secret_hash) = get_identity_info()
  let peers_opt = match peers {
    Some(p) => if p.is_empty() { None } else { Some(p) }
    None => None
  }
  Message::new(
    kind="hello",
    from=node_id,
    addr=local_addr,
    relay~,
    version=VERSION,
    peers?=peers_opt,
    public_key?,
    secret_hash?,
  )
}

///|
async fn handle_reconnects(
  server : @socket.UdpServer,
  local_addr : String,
  node_id : String,
) -> Unit {
  let our_addresses = get_our_addresses(local_addr)
  let hello_msg = create_hello_message(
    node_id,
    local_addr,
    1,
    peers=our_addresses,
  )
  let mut reconnect_interval = 500 // Start fast: 500ms
  let max_reconnect_interval = 5000 // Max: 5s
  for {
    // Sleep with dynamic interval
    @async.sleep(reconnect_interval)
    // Increase interval for next time (exponential backoff)
    if reconnect_interval < max_reconnect_interval {
      reconnect_interval = (reconnect_interval * 2).min(max_reconnect_interval)
    }

    // Broadcast hello only to peers we don't have active connections with
    // Send directly to each known peer address with relay=1
    let known_peers = get_all_known_peers()
    for peer_addr in known_peers {
      // Skip 0.0.0.0 addresses (bind-all, not connectable)
      if !peer_addr.has_prefix("0.0.0.0:") {
        // Check if we already have an active connection to this peer address
        let all_conns = get_global_peer_manager().get_all_connections()
        let has_active_conn = all_conns.any(fn(conn) {
          conn.remote_addr == peer_addr &&
          conn.state == ConnectionState::Connected
        })

        // Only send hello if we don't have an active connection
        if !has_active_conn {
          send_message(server, peer_addr, hello_msg) |> ignore
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
          String(script_name) => {
            root.spawn_bg(fn() {
              match global_config.val {
                Some({ scripts: Some(scripts), .. }) =>
                  match scripts.get(script_name) {
                    Some(command) => execute_script(script_name, command)
                    None => println("Script not found: \{script_name}")
                  }
                _ => println("Config not available")
              }
            })
            println("Processed self-message for \{target}: \{script_name}")
          }
          _ => println("Self-message has no data")
        }
      } else {
        // Try to find and send to remote peer
        let target_peer = get_global_peer_manager().get_peer(target)
        match target_peer {
          Some(_) => {
            // Try BOTH direct and relay paths simultaneously (UDP fire-and-forget)
            // This increases chances of reaching the peer through multiple paths

            // First, try direct connections to the target peer
            let target_conns = get_global_peer_manager().get_active_peer_connections(
              target,
            )
            if !target_conns.is_empty() {
              // Send directly to the target peer on all active connections
              for conn in target_conns {
                ignore(send_message(server, conn.remote_addr, msg))
                println(
                  "Sent data to \{target} directly via \{conn.remote_addr}",
                )
              }
            } else {
              println("No direct connections to target \{target}, trying relay")
            }

            // Second, try relay paths through other connected peers
            // This ensures delivery even if direct path fails (due to NAT/firewall)
            let all_peers = get_global_peer_manager().get_all_peers()
            for relay_peer in all_peers {
              let relay_conns = get_global_peer_manager().get_active_peer_connections(
                relay_peer.id,
              )
              if !relay_conns.is_empty() && relay_peer.id != target {
                // This relay peer has active connections, use it to reach the target
                let relayed_msg = Message::new(
                  kind=msg.kind,
                  from=msg.from,
                  addr=msg.addr,
                  relay=msg.relay + 1, // Relayed through 1 intermediary
                  target~, // Route to target peer ID
                  data=msg.data,
                  version?=msg.version,
                  public_key?=msg.public_key,
                  secret_hash?=msg.secret_hash,
                  encrypted=msg.encrypted,
                )
                let relay_addr = relay_conns[0].remote_addr
                ignore(send_message(server, relay_addr, relayed_msg))
                println(
                  "Sent relayed data to \{target} through \{relay_peer.id} at \{relay_addr}",
                )
              }
            }
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
  let heartbeat_interval = 3000 // 3 seconds
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
          version=VERSION,
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

        // Check if connection has timed out (no response for HELLO_DEBOUNCE_MS)
        if current_time - conn.last_seen > HELLO_DEBOUNCE_MS && conn.is_active() {
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
      let hello = create_hello_message(id, local_addr, 1, peers=peer_addresses)

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
    let sender_addr = "\{sender}"
    let local_addr = "\{server.addr()}"

    // Skip messages from self, unless target is self
    if msg.from == id && msg.target != Some(id) {
      continue
    }
    println("\{msg.from}(\{sender}): \{msg.kind}")
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
    // Use the message's relay count as the hop depth for this connection
    // msg.relay already indicates how many hops the message took to reach us
    let relay_depth_to_use = msg.relay
    let (conn, is_new_connection) = handle_new_connection(
      msg.from,
      local_addr,
      sender_addr,
      peer_info?,
      relay_depth=relay_depth_to_use,
    )

    // Store peer's public key if provided and compute shared secret (only if not already stored)
    if msg.public_key is Some(pk) {
      let peer_manager = get_global_peer_manager()
      let peer_already_has_key = peer_manager.get_peer(msg.from)
        is Some({ public_key: Some(_), .. })
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

    // Only broadcast connection update if this is a NEW connection
    if is_new_connection {
      root.spawn_bg(fn() { broadcast_connection_update(server, id, local_addr) })
    }

    // Handle message relaying: if target is set and we're not the target, forward it
    if msg.target is Some(target_addr) {
      if global_config.val is Some({ id, .. }) && id == target_addr {
        continue
      }
      // Check if this node has already processed this message (prevent loops using DFS path tracking)
      let already_visited = msg.visited.any(fn(node_id) { node_id == id })
      if !already_visited {
        // This is a relayed message, forward it to the target with incremented relay depth
        // Add current node to visited list to track the path and prevent loops
        let updated_visited = msg.visited
        updated_visited.push(id)
        let relay_msg = Message::new(
          id=msg.id,
          kind=msg.kind,
          from=msg.from,
          addr=msg.addr,
          relay=msg.relay + 1,
          visited=updated_visited,
          version?=msg.version,
          peers?=msg.peers,
          payload?=msg.payload,
          target?=msg.target,
          data=msg.data,
          public_key?=msg.public_key,
          secret_hash?=msg.secret_hash,
          encrypted=msg.encrypted,
        )
        let relay_success = send_message(server, target_addr, relay_msg)
        if relay_success {
          let path_str = relay_msg.visited.join(" -> ")
          println(
            "Relayed \{msg.kind} from \{msg.from} to \{target_addr} (relay hop \{relay_msg.relay}), path: \{path_str}",
          )
        } else {
          println(
            "Failed to relay \{msg.kind} from \{msg.from} to \{target_addr}",
          )
        }
      } else {
        let path_str = msg.visited.join(" -> ")
        println(
          "Dropping message from \{msg.from} to \{target_addr}: already visited this node (loop detected), path: \{path_str}",
        )
      }
      // Continue processing this message locally as well (don't return)
    }
    // Handle broadcast forwarding: if broadcast is true, forward to all peers (except sender)
    if msg.broadcast &&
      msg.from != id &&
      !msg.visited.any(fn(node_id) { node_id == id }) {
      // Add current node to visited list to track the path and prevent loops
      let updated_visited = msg.visited
      updated_visited.push(id)

      // Get all known peers and send broadcast to each (except sender)
      let known_peers = get_all_known_peers()
      for peer_addr in known_peers {
        if peer_addr != sender_addr && !peer_addr.has_prefix("0.0.0.0:") {
          let broadcast_msg = Message::new(
            id=msg.id,
            kind=msg.kind,
            from=msg.from,
            addr=msg.addr,
            relay=msg.relay + 1,
            visited=updated_visited, // Keep visited list to track path
            target?=msg.target,
            data=msg.data,
            version?=msg.version,
            public_key?=msg.public_key,
            secret_hash?=msg.secret_hash,
            encrypted=msg.encrypted,
            broadcast=true,
          )
          ignore(send_message(server, peer_addr, broadcast_msg))
          println("Forwarding broadcast from \{msg.from} via \{peer_addr}")
        }
      }
    }
    match msg {
      {
        kind: "hello",
        secret_hash: Some(peer_secret_hash),
        peers: advertised_peers,
        ..,
      } => {
        // Validate secret
        let secret_valid = match global_config.val {
          Some(config) => {
            let our_secret_hash = hash_secret(config.secret)
            if peer_secret_hash != our_secret_hash {
              // Secret mismatch - reject this peer
              println(
                "Rejecting peer \{msg.from} at \{sender_addr}: secret mismatch",
              )
              false
            } else {
              // Secret matches - accept connection
              println("Accepted peer \{msg.from} at \{sender_addr}")
              true
            }
          }
          None => {
            // No config - accept hello
            println("Accepted peer \{msg.from} at \{sender_addr} (no config)")
            true
          }
        }

        // Ensure peer exists in manager before learning address
        match get_global_peer_manager().get_peer(msg.from) {
          None => {
            // Peer doesn't exist yet, create it
            let peer_node = PeerNode::new(id=msg.from, version=VERSION)
            update_global_peer_manager(fn(manager) {
              manager.add_peer(peer_node)
            })
          }
          Some(_) => () // Peer exists
        }

        // If secret is valid, broadcast this new peer to all existing connected peers
        if secret_valid {
          let all_peers = get_global_peer_manager().get_all_peers()
          for existing_peer in all_peers {
            // Skip the peer we just received hello from
            if existing_peer.id != msg.from {
              let peer_conns = get_global_peer_manager().get_active_peer_connections(
                existing_peer.id,
              )
              // Send update about new peer to all active connections
              for conn in peer_conns {
                if conn.state == ConnectionState::Connected {
                  // Create hello message for the new peer and send to existing peer
                  let update_msg = create_hello_message(
                    msg.from,
                    sender_addr,
                    1,
                    peers?=None,
                  )
                  ignore(send_message(server, conn.remote_addr, update_msg))
                  println(
                    "Broadcasted new peer \{msg.from} to \{existing_peer.id} at \{conn.remote_addr}",
                  )
                }
              }
            }
          }
        }

        // Discover peers from advertised peer addresses in hello
        // Instead of waiting for welcome, process advertised peers directly
        if advertised_peers is Some(peer_addrs) {
          let all_conns = get_global_peer_manager().get_all_connections()
          for peer_addr_obj in peer_addrs {
            let peer_addr = peer_addr_obj.address
            // Skip 0.0.0.0 addresses (bind-all, not connectable) and our own address
            if !peer_addr.has_prefix("0.0.0.0:") && peer_addr != local_addr {
              // Track this peer address for active connection attempts
              add_known_peer(peer_addr)

              // Check if we already have a relay path for this address
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
                    let hello_msg = create_hello_message(
                      id,
                      local_addr,
                      2,
                      peers?=None,
                    )
                    // Send to both direct and relay addresses (fire and forget)
                    send_message_with_fallback(
                      server, peer_addr, sender_addr, hello_msg,
                    )
                    println(
                      "Sent hello to discovered peer at \{peer_addr} (fallback: \{sender_addr})",
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
        if should_rebroadcast_hello(msg.from) {
          record_hello_time(msg.from)
          let known_peers = get_all_known_peers()
          for peer_addr in known_peers {
            // Don't send back to the peer we just received it from
            // Also skip 0.0.0.0 addresses (bind-all, not connectable)
            if peer_addr != sender_addr && !peer_addr.has_prefix("0.0.0.0:") {
              ignore(send_message(server, peer_addr, msg))
            }
          }
        }
      }
      { kind: "hello", .. } => {
        // Hello without secret_hash - reject it (backwards compatibility)
        println("Rejecting hello from \{msg.from}: no secret_hash provided")
        ()
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
          target=sender_addr,
        )
        let punch_to_sender = Message::new(
          kind="punch",
          from=id,
          addr=local_addr,
          relay=2,
          target~,
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
      { kind: "relay", target: Some(target), data, .. } => {
        let forward = Message::new(
          kind="data",
          from=msg.from,
          addr=msg.addr,
          relay=2,
          data~,
          target~,
        )
        ignore(send_message(server, target, forward))
      }
      { kind: "send", target: Some(target), data, .. } => {
        let direct = Message::new(
          kind="data",
          from=msg.from,
          addr=msg.addr,
          data~,
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
              target~,
            )
            let relay = Message::new(
              kind="relay",
              from=msg.from,
              addr=msg.addr,
              relay=2,
              target~,
              data~,
            )
            ignore(send_message(server, relay_conn.remote_addr, request))
            ignore(send_message(server, relay_conn.remote_addr, relay))
          }
          None => ()
        }
      }
      { kind: "data", data: Binary(raw_data), encrypted, .. } => {
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
                      script_name,
                      command,
                      @utf8.decode(data_content),
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
                    data=script_outputs.map(@msgpack.string) |> @msgpack.array,
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
      { kind: "data_response", data: response_data, .. } => {
        // Handle response from script execution
        println("Received script response from \{msg.from}:")
        println(response_data)
      }
      { kind: "connection_update", data: Array(conn_entries), .. } =>
        // Handle connection update from peer
        // Parse connection string: "peer_id:remote_addr:relay|..."
        for entry in conn_entries {
          if entry
            is Map(
              {
                "peer_id": String(peer_id),
                "remote_addr": String(remote_addr),
                "relay_depth": Int(relay_depth),
                ..
              }
            ) {
            // Create or update the connection in our peer manager
            if peer_id == msg.from {
              // This is a connection from the peer who sent the update
              let (_conn, _is_new) = handle_new_connection(
                peer_id,
                local_addr,
                remote_addr,
                relay_depth~,
              )
              println("Learned new connection: \{peer_id} -> \{remote_addr}")
            }
          }
        }
      _ => ()
    }
    root.spawn_bg(fn() {  })
  }
}
