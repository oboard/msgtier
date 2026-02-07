///|
const CONNECTION_TIMEOUT_MS : UInt64 = 30000 // 30 seconds timeout

///|
fn handle_new_connection(
  peer_id : String,
  local_addr : String,
  remote_addr : String,
  protocol : String,
  peer_info? : NetworkDiscoveryInfo,
  relay_depth? : Int = 1,
) -> (Connection, Bool, Bool) {
  // Get the actual peer ID (from peer_info if available, otherwise from peer_id parameter)
  let actual_peer_id = if peer_info is Some(info) { info.id } else { peer_id }

  // Prevent connecting to self
  // If we are connecting to ourselves, return a dummy connected connection
  // and do NOT add it to the connection manager.
  let my_id = get_config().id
  if actual_peer_id == my_id && !my_id.is_empty() {
    let dummy_conn = Connection::new(
      my_id, actual_peer_id, local_addr, remote_addr, protocol,
    )
    let dummy_conn = { ..dummy_conn, state: ConnectionState::Connected }
    return (dummy_conn, false, false)
  }
  let mut is_new_peer = false

  // Add or update peer with provided info
  if peer_info is Some(info) {
    let peer_node = PeerNode::new(
      id=info.id,
      version=info.version,
      public_key=info.public_key,
      addresses=[remote_addr],
      metadata={},
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
        return (existing_conn, false, is_new_peer)
      }
    }
  }

  // Add new connection with protocol
  update_global_connection_manager(fn(manager) {
    let my_id = get_config().id
    let mgr = manager.add_connection(
      Connection::new(my_id, actual_peer_id, local_addr, remote_addr, protocol),
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
  (conn, true, is_new_peer)
}

///|
struct ScriptOutput {
  exit_code : Int
  output : String
} derive(ToJson)

///|
fn ScriptOutput::to_msgpack(self : ScriptOutput) -> @msgpack.Value {
  @msgpack.map({
    "exit_code": @msgpack.int(self.exit_code),
    "output": @msgpack.string(self.output),
  })
}

///|
async fn execute_script_handler(content : String) -> ScriptOutput? {
  match global_config.val {
    Some({ scripts: Some(scripts), .. }) =>
      Some(process_script_execution(content, scripts))
    _ => None
  }
}

///|
async fn execute_script_with_output(
  program : String,
  args : Array[String],
  input_data : String,
) -> ScriptOutput {
  // Create a pipe for stdin if we have input data
  let (stdin_r, stdin_w) = @pipe.pipe()
  let (stdout_r, stdout_w) = @pipe.pipe()

  // Write input data to stdin pipe in a background task
  if input_data.length() > 0 {
    // Write input and close write end
    stdin_w.write(@utf8.encode(input_data)) |> ignore
  }
  stdin_w.close()
  defer stdout_r.close()
  defer stdin_r.close()

  // Execute and capture output directly
  let exit_code = @process.run(program, args, stdin=stdin_r, stdout=stdout_w)
  stdout_w.close()
  { exit_code, output: stdout_r.read_all().text() }
}

///|
fn get_best_connection_for_peer(peer_id : String) -> Connection? {
  // Use the intelligent connection selection that prefers direct connections
  get_global_connection_manager().get_best_direct_connection(peer_id)
}

///|
async fn send_message(
  transport : &Transport,
  peer : String,
  msg : Message,
) -> Bool noraise {
  if peer.is_empty() {
    return false
  }

  // Protocol check: ensure target address matches transport protocol
  if peer.contains("://") {
    let protocol = transport.protocol()
    if !peer.has_prefix(protocol + "://") {
      return false
    }
  }
  try {
    let msgpack_bytes = msg.to_msgpack()
    transport.send(peer, msgpack_bytes)
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
  transport : &Transport,
  primary_addr : String,
  fallback_addr : String,
  msg : Message,
) -> Unit noraise {
  let protocol = transport.protocol()

  // Try primary address - fire and forget
  if !primary_addr.is_empty() {
    // Check protocol compatibility
    let compatible = !primary_addr.contains("://") ||
      primary_addr.has_prefix(protocol + "://")
    if compatible {
      try {
        let msgpack_bytes = msg.to_msgpack()
        transport.send(primary_addr, msgpack_bytes) |> ignore
        println("Sent to primary \{primary_addr}")
      } catch {
        _ => println("Failed to send to primary \{primary_addr}")
      }
    }
  }

  // Try fallback address - fire and forget
  if !fallback_addr.is_empty() && fallback_addr != primary_addr {
    // Check protocol compatibility
    let compatible = !fallback_addr.contains("://") ||
      fallback_addr.has_prefix(protocol + "://")
    if compatible {
      try {
        let msgpack_bytes = msg.to_msgpack()
        transport.send(fallback_addr, msgpack_bytes) |> ignore
        println("Sent to fallback \{fallback_addr}")
      } catch {
        _ => println("Failed to send to fallback \{fallback_addr}")
      }
    }
  }
}

///|
fn get_identity_info() -> (Bytes, String) {
  let our_public_key = get_public_key()
  let our_secret_hash = match global_config.val {
    Some(config) => hash_secret(config.secret)
    None => abort("No config found")
  }
  (our_public_key, our_secret_hash)
}

///|
fn get_our_addresses(local_addr : String) -> Array[NetworkAddress] {
  match global_config.val {
    Some(config) => {
      let addrs : Array[NetworkAddress] = []
      for listener_url in config.listeners {
        let addr_str = listener_url.to_string()
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
fn create_sync_message(peer_id : String, local_addr : String) -> Message {
  // Create a message that includes all current connections of this node
  let all_peers = get_global_peer_manager().get_all_peers()
  let all_conns = get_global_connection_manager().get_all_connections()
  let connections_data : Array[@msgpack.Value] = []

  // Include direct connections (hops=1)
  for peer in all_peers {
    let peer_conns = peer.get_all_connections(all_conns)
    for conn in peer_conns {
      if conn.is_active() {
        let pk = peer.public_key
        let elapsed_ms = @env.now() - conn.last_seen
        let bandwidth_mbps = conn.calculate_bandwidth_mbps(elapsed_ms)
        let packet_loss_rate = conn.calculate_packet_loss()
        let sync_conn = SyncConnection::{
          peer_id: peer.id,
          remote_addr: conn.remote_addr,
          relay: conn.relay,
          public_key: pk,
          latency_ms: conn.latency_ms,
          bandwidth_mbps,
          packet_loss_rate,
          id: conn.id,
          protocol: conn.protocol,
          local_addr: conn.local_addr,
          state: conn.state.to_string(),
          last_seen: conn.last_seen,
          quality: conn.quality,
          metadata: conn.metadata,
          latency_history: conn.latency_history,
          packets_sent: conn.packets_sent,
          packets_lost: conn.packets_lost,
          bytes_sent: conn.bytes_sent,
          bytes_received: conn.bytes_received,
          last_ping_time: conn.last_ping_time,
          version: peer.version,
        }
        connections_data.push(sync_conn.to_msgpack())
      }
    }
  }

  // Include known routes (hops > 1)
  let all_routes = get_global_peer_manager().get_all_routes()
  for peer_id, route in all_routes {
    // Only advertise routes that are NOT direct connections (to avoid duplication)
    // and valid routes
    if route.hops > 1 {
      match get_global_peer_manager().get_peer(peer_id) {
        Some(peer) => {
          let pk = peer.public_key
          let sync_conn = SyncConnection::{
            peer_id,
            remote_addr: "routed",
            relay: route.hops,
            public_key: pk,
            latency_ms: None,
            bandwidth_mbps: 0.0,
            packet_loss_rate: 0,
            id: "",
            protocol: "",
            local_addr: "",
            state: "Routed",
            last_seen: route.timestamp,
            quality: 0,
            metadata: None,
            latency_history: [],
            packets_sent: 0,
            packets_lost: 0,
            bytes_sent: 0,
            bytes_received: 0,
            last_ping_time: None,
            version: peer.version,
          }
          connections_data.push(sync_conn.to_msgpack())
        }
        None => ()
      }
    }
  }
  Message::new(
    kind="sync",
    from=peer_id,
    addr=local_addr,
    relay=1,
    broadcast=true,
    data=@msgpack.array(connections_data),
  )
}

///|
async fn broadcast_sync(
  transport : &Transport,
  peer_id : String,
  local_addr : String,
) -> Unit {
  let update_msg = create_sync_message(peer_id, local_addr)
  let all_peers = get_global_peer_manager().get_all_peers()
  for peer in all_peers {
    let peer_conns = get_global_connection_manager().get_active_connections(
      peer.id,
    )
    for conn in peer_conns {
      if conn.state == ConnectionState::Connected {
        // Only send if connection protocol matches transport protocol
        if conn.protocol == transport.protocol() {
          ignore(send_message(transport, conn.remote_addr, update_msg))
        }
      }
    }
  }
}

///|
fn create_hello_message(
  peer_id : String,
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
    from=peer_id,
    addr=local_addr,
    relay~,
    version=VERSION,
    peers?=peers_opt,
    public_key~,
    secret_hash~,
  )
}

///|
async fn handle_reconnects(
  transport : &Transport,
  local_addr : String,
  peer_id : String,
) -> Unit {
  let our_addresses = get_our_addresses(local_addr)
  let hello_msg = create_hello_message(
    peer_id,
    local_addr,
    1,
    peers=our_addresses,
  )
  let reconnect_interval = 5000 // Fixed interval: 5s
  for {
    // Sleep with fixed interval
    @async.sleep(reconnect_interval)
    // Broadcast hello only to peers we don't have active connections with
    // Send directly to each known peer address with relay=1
    let known_peers = get_all_known_peers()
    for peer_addr in known_peers {
      // Parse URL to check protocol
      if !peer_addr.has_prefix(transport.protocol() + "://") {
        continue
      }

      // Check if we already have an active connection to this peer address
      let all_conns = get_global_connection_manager().get_all_connections()
      let has_active_conn = all_conns.any(conn => conn.remote_addr == peer_addr &&
        conn.state == ConnectionState::Connected)

      // Only send hello if we don't have an active connection
      if !has_active_conn {
        // println("Attempting reconnection to \{target_addr}...")
        send_message(transport, peer_addr, hello_msg) |> ignore
      }
    }
  }
}

///|
fn parse_command_args(command : String) -> Array[String] {
  let args = []
  let mut current_arg = StringBuilder::new()
  let mut in_single_quote = false
  let mut in_double_quote = false
  let mut escaped = false
  for i = 0; i < command.length(); i = i + 1 {
    let c = command[i].to_int().unsafe_to_char()
    if escaped {
      current_arg.write_char(c)
      escaped = false
    } else {
      match c {
        '\\' => escaped = true
        '\'' =>
          if !in_double_quote {
            in_single_quote = !in_single_quote
          } else {
            current_arg.write_char(c)
          }
        '"' =>
          if !in_single_quote {
            in_double_quote = !in_double_quote
          } else {
            current_arg.write_char(c)
          }
        ' ' | '\t' | '\n' | '\r' =>
          if in_single_quote || in_double_quote {
            current_arg.write_char(c)
          } else if current_arg.to_string().length() > 0 {
            args.push(current_arg.to_string())
            current_arg = StringBuilder::new()
          }
        _ => current_arg.write_char(c)
      }
    }
  }
  if current_arg.to_string().length() > 0 {
    args.push(current_arg.to_string())
  }
  args
}

///|
async fn process_script_execution(
  content_str : String,
  scripts : Map[String, String],
) -> ScriptOutput {
  let parts = content_str.split(" ").to_array()
  let (name, args) = match parts {
    [name, .. args] => (name, args)
    _ => {
      let empty : Array[StringView] = []
      (""[:], empty[:])
    }
  }
  match scripts.get(name.to_string()) {
    Some(command) => {
      // Split command string into program and args using proper parser
      let cmd_parts = parse_command_args(command)
      let (program, cmd_args) = match cmd_parts {
        [prog, .. rest] => (prog, rest)
        _ => ("", [])
      }

      // Append user-provided args to command args
      let final_args = []
      final_args.push_iter(cmd_args.iter())
      final_args.push_iter(args.iter().map(fn(s) { s.to_string() }))
      println("[script]\t\{content_str}")
      execute_script_with_output(program, final_args, "")
    }
    None => {
      println("Script not found: \{content_str}")
      { exit_code: 1, output: "Script not found: \{content_str}" }
    }
  }
}

///|
async fn handle_pending_messages(
  transport : &Transport,
  peer_id : String,
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
      if target == peer_id {
        // Handle message to self directly
        // Extract content from message data
        let content_opt = match msg.data {
          String(s) => Some(s)
          Binary(raw) =>
            // Try to decrypt if encrypted (though we prefer String for self)
            if msg.encrypted {
              match decrypt_from_peer(peer_id, raw) {
                Some(d) => Some(@utf8.decode(d))
                None => None
              }
            } else {
              Some(@utf8.decode(raw))
            }
          _ => None
        }
        match content_opt {
          Some(content) =>
            match execute_script_handler(content) {
              Some(output) =>
                resolve_request(
                  msg.id,
                  { "code": output.exit_code.to_string() },
                  @utf8.encode(output.output),
                )
              None =>
                println("PendingMessage: self-config-missing id=\{msg.id}")
            }
          None => println("PendingMessage: self-no-data id=\{msg.id}")
        }
      } else {
        // Try to find and send to remote peer
        let target_peer = get_global_peer_manager().get_peer(target)

        // Strategy:
        // 1. Try direct connection
        // 2. Try routed connection (via next_hop)
        // 3. Fallback to broadcast/relay (optional, maybe keep for robustness)

        // 1. Direct connection
        let target_conns = get_global_connection_manager().get_active_connections(
          target,
        )
        if !target_conns.is_empty() {
          // Select the best connection based on quality/protocol preference
          // For now, just pick the first one to avoid duplication (corruption)
          // Ideally we should prefer TCP/QUIC over UDP for large data
          // And match transport protocol if possible
          let mut best_conn = target_conns[0]

          // Simple heuristic: try to find a connection with same protocol as transport
          // This avoids cross-protocol bridging overhead if not needed
          for conn in target_conns {
            if conn.protocol == transport.protocol() {
              best_conn = conn
              break
            }
          }
          ignore(send_message(transport, best_conn.remote_addr, msg))
          println(
            "Sent data to \{target} directly via \{best_conn.remote_addr}",
          )
          println("PendingMessage: sent id=\{msg.id} target=\{target}")
          continue
        }

        // 2. Routed connection
        match get_global_peer_manager().get_route(target) {
          Some(route) => {
            let next_hop = route.next_hop
            let next_hop_conns = get_global_connection_manager().get_active_connections(
              next_hop,
            )
            if !next_hop_conns.is_empty() {
              let next_hop_addr = next_hop_conns[0].remote_addr
              // We keep target set in the message so next hop knows where to forward
              let routed_msg = Message::{ ..msg, target: Some(target) }
              ignore(send_message(transport, next_hop_addr, routed_msg))
              println(
                "Sent data to \{target} via route \{next_hop} (\{next_hop_addr})",
              )
              println("PendingMessage: routed id=\{msg.id} target=\{target}")
              continue
            } else {
              println(
                "Route to \{target} via \{next_hop} exists but next hop is not connected",
              )
            }
          }
          None => ()
        }

        // 3. Fallback: Relay through all connected peers (Flood/Gossip)
        // Only do this if we haven't sent it yet
        match target_peer {
          Some(_) => {
            println("No route to \{target}, trying flood relay")
            let all_peers = get_global_peer_manager().get_all_peers()
            for relay_peer in all_peers {
              let relay_conns = get_global_connection_manager().get_active_connections(
                relay_peer.id,
              )
              if !relay_conns.is_empty() && relay_peer.id != target {
                let relayed_msg = Message::new(
                  kind=msg.kind,
                  from=msg.from,
                  addr=msg.addr,
                  relay=msg.relay + 1,
                  target~,
                  data=msg.data,
                  version?=msg.version,
                  public_key?=msg.public_key,
                  secret_hash?=msg.secret_hash,
                  encrypted=msg.encrypted,
                )
                let relay_addr = relay_conns[0].remote_addr
                ignore(send_message(transport, relay_addr, relayed_msg))
                println(
                  "PendingMessage: relayed id=\{msg.id} target=\{target} via=\{relay_addr}",
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
  transport : &Transport,
  local_addr : String,
  from : String,
) -> Unit {
  let heartbeat_interval = 3000 // 3 seconds
  for {
    @async.sleep(heartbeat_interval)
    let current_time = @env.now()
    let all_peers = get_global_peer_manager().get_all_peers()
    for peer in all_peers {
      let peer_id = peer.id
      let peer_conns = get_global_connection_manager().get_peer_connections(
        peer_id,
      )

      // Send ping to all connections of this peer
      for conn in peer_conns {
        let ping_msg = Message::new(
          kind="ping",
          from~,
          addr=local_addr,
          version=VERSION,
        )
        // Record ping time before sending
        update_global_connection_manager(fn(manager) {
          manager.update_connection_ping_time(conn.id, Some(current_time))
        })
        // Increment packets_sent counter
        update_global_connection_manager(fn(manager) {
          manager.update_connection_packet_loss(conn.id, 1, 0)
        })
        ignore(send_message(transport, conn.remote_addr, ping_msg))

        // Check if connection has timed out (no response for CONNECTION_TIMEOUT_MS)
        if current_time - conn.last_seen > CONNECTION_TIMEOUT_MS &&
          conn.is_active() {
          println("Connection to \{peer_id} at \{conn.remote_addr} timed out")
          update_global_connection_manager(fn(manager) {
            manager.update_connection_state(
              conn.id,
              ConnectionState::Disconnected,
            )
          })
          // Broadcast update because a connection became inactive
          ignore(broadcast_sync(transport, from, local_addr))
        }
      }
    }
  }
}

///|
async fn handle_periodic_updates(
  transport : &Transport,
  peer_id : String,
  local_addr : String,
) -> Unit {
  let update_interval = 5000 // 5 seconds
  for {
    @async.sleep(update_interval)
    broadcast_sync(transport, peer_id, local_addr) |> ignore
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
      println(
        "DEBUG: Msgpack decode error - \{error_msg}, sender: \{sender_addr}, bytes: \{bytes.length()}",
      )
      // Log first 20 bytes for debugging
      if bytes.length() > 0 {
        let preview_len = bytes.length().min(20)
        let preview = bytes[:preview_len]
        println(
          "DEBUG: Message preview (first \{preview_len} bytes): \{bytes_to_hex(preview.to_bytes())}",
        )
      }
      return
    }
  }
  let msg : Message = Message::from_msgpack(msgpack_value) catch {
    _ => {
      println(
        "Failed to decode message: \{msgpack_value.to_json().stringify()}",
      )
      return
    }
  }
  // Skip messages from self, unless target is self
  if msg.from == id && msg.target != Some(id) {
    return
  }
  // Logger
  println("[\{msg.kind}]\t\{msg.from}(\{sender_addr})")
  // Handle the connection - always create/update connection for any message
  // Determine connectable address from hello message
  let connectable_addr = if msg.kind == "hello" && !msg.addr.is_empty() {
    // Ensure address has protocol
    let addr_str = if msg.addr.contains("://") {
      msg.addr
    } else {
      transport.protocol() + "://" + msg.addr
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
        id: msg.from,
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
  // Use connectable_addr (listening address) if available, otherwise fallback to sender_addr
  // This ensures we register the stable listening address for the connection
  let effective_addr = if !connectable_addr.is_empty() {
    connectable_addr
  } else {
    sender_addr
  }
  let (conn, is_new_connection, is_new_peer) = handle_new_connection(
    msg.from,
    local_addr,
    effective_addr,
    transport.protocol(),
    peer_info?,
    relay_depth=relay_depth_to_use,
  )
  if is_new_peer ||
    (msg.kind == "hello" && conn.state != ConnectionState::Connected) {
    // Send hello to new peer
    let our_addresses = get_our_addresses(local_addr)
    let hello_msg = create_hello_message(id, local_addr, 1, peers=our_addresses)
    // Use conn.remote_addr to ensure we reply to the stable address (not ephemeral)
    ignore(send_message(transport, conn.remote_addr, hello_msg))
    // println("Sent hello to new peer \{msg.from} at \{conn.remote_addr}")

    // Broadcast sync
    try broadcast_sync(transport, id, local_addr) |> ignore catch {
      _ => println("Failed to broadcast sync for new peer")
    }
    // println("Broadcasted sync for new peer \{msg.from}")
  }

  // Check if state is changing from non-Connected to Connected
  let was_disconnected = conn.state != ConnectionState::Connected

  // Store peer's public key if provided and compute shared secret (only if not already stored)
  if msg.public_key is Some(pk) {
    compute_and_store_shared_secret(msg.from, pk)
  }

  // Track bytes received
  update_global_connection_manager(fn(manager) {
    manager.update_connection_bytes(conn.id, 0UL, bytes.length().to_uint64())
  })

  // Update connection state to Connected and update last_seen timestamp
  update_global_connection_manager(fn(manager) {
    let manager = manager.update_connection_state(
      conn.id,
      ConnectionState::Connected,
    )
    // Use current time as timestamp
    let timestamp = @env.now() // Far future to prevent timeout
    manager.update_connection_last_seen(conn.id, timestamp)
  })

  // Only broadcast connection update if this is a NEW connection or state changed to Active
  if is_new_connection || was_disconnected {
    root.spawn_bg(fn() { broadcast_sync(transport, id, local_addr) })
  }

  // Handle message relaying: if target is set and we're not the target, forward it
  if msg.target is Some(target_peer_id) {
    if global_config.val is Some({ id, .. }) && id == target_peer_id {
      // Message is for us, continue to process
    } else {
      // Message is for someone else, forward it
      // Check if this node has already processed this message (prevent loops using DFS path tracking)
      let already_visited = msg.visited.any(peer_id => peer_id == id)
      if !already_visited {
        let updated_visited = msg.visited
        updated_visited.push(id)
        let relay_msg = Message::{
          ..msg,
          relay: msg.relay + 1,
          visited: updated_visited,
        }

        // Use routing table to forward
        let mut forwarded = false

        // 1. Direct connection check
        let target_conns = get_global_connection_manager().get_active_connections(
          target_peer_id,
        )
        if !target_conns.is_empty() {
          for conn in target_conns {
            ignore(send_message(transport, conn.remote_addr, relay_msg))
          }
          forwarded = true
          let path_str = relay_msg.visited.join(" -> ")
          println("Forwarded to \{target_peer_id} directly, path: \{path_str}")
        }

        // 2. Routing table check
        if !forwarded {
          match get_global_peer_manager().get_route(target_peer_id) {
            Some(route) => {
              let next_hop = route.next_hop
              let next_hop_conns = get_global_connection_manager().get_active_connections(
                next_hop,
              )
              if !next_hop_conns.is_empty() {
                let next_hop_addr = next_hop_conns[0].remote_addr
                ignore(send_message(transport, next_hop_addr, relay_msg))
                forwarded = true
                let path_str = relay_msg.visited.join(" -> ")
                println(
                  "Forwarded to \{target_peer_id} via \{next_hop}, path: \{path_str}",
                )
              }
            }
            None => ()
          }
        }

        // 3. Fallback to broadcast/flood if no route (optional, but good for discovery)
        if !forwarded {
          // ... existing flood logic?
          // Maybe better to just drop if no route to avoid network storm
          // But for now, let's just log failure
          println(
            "Failed to route message to \{target_peer_id}: no route found",
          )
        }

        // Stop processing locally (since it was forwarded or dropped)
        return
      } else {
        let path_str = msg.visited.join(" -> ")
        println(
          "Dropping message from \{msg.from} to \{target_peer_id}: already visited this node (loop detected), path: \{path_str}",
        )
        return
      }
    }
  }

  // Handle broadcast forwarding: if broadcast is true, forward to all peers (except sender)
  if msg.broadcast &&
    msg.from != id &&
    !msg.visited.any(fn(peer_id) { peer_id == id }) {
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
        ignore(send_message(transport, peer_addr, broadcast_msg))
        // println("[broadcast]\t\{msg.from}(\{sender_addr}) -> \{peer_addr}")
      }
    }
  }
  match msg {
    {
      kind: "hello",
      secret_hash: Some(peer_secret_hash),
      from,
      peers: advertised_peers,
      public_key: Some(public_key),
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
            // println("Accepted peer \{msg.from} at \{sender_addr}")
            true
          }
        }
        None =>
          // No config - accept hello
          // println("Accepted peer \{msg.from} at \{sender_addr} (no config)")
          true
      }
      if !secret_valid {
        return
      }

      // Ensure peer exists in manager before learning address
      match get_global_peer_manager().get_peer(msg.from) {
        None => {
          // Peer doesn't exist yet, create it
          let peer_node = PeerNode::new(
            id=msg.from,
            version=VERSION,
            public_key~,
            addresses=[msg.addr],
            metadata={},
          )
          update_global_peer_manager(fn(manager) { manager.add_peer(peer_node) })
        }
        Some(_) => () // Peer exists
      }

      // Discover peers from advertised peer addresses in hello
      // Instead of waiting for welcome, process advertised peers directly
      if advertised_peers is Some(peer_addrs) {
        let all_conns = get_global_connection_manager().get_all_connections()
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
                  conn.peer_id == from
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
                    transport, peer_addr, sender_addr, hello_msg,
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
            ignore(send_message(transport, peer_addr, msg))
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
      ignore(send_message(transport, sender_addr, reply))
    }
    { kind: "pong", .. } => {
      // Heartbeat response received - mark connection as healthy
      let peer_id = msg.from
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
      add_pending_message(target, punch_to_target)
      // sender_addr is an IP/port, so we can send directly or use pending
      // using pending is safer for consistency
      ignore(send_message(transport, sender_addr, punch_to_sender))
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
      add_pending_message(target, ack_to_target)
      ignore(send_message(transport, sender_addr, ack_to_sender))
    }
    { kind: "relay", target: Some(target), data, .. } => {
      let forward = Message::new(
        kind="data",
        from=msg.from,
        addr=msg.addr,
        relay=2,
        data~,
        target~,
        encrypted=true, // Ensure relay messages preserve encryption flag if originally encrypted
      )
      add_pending_message(target, forward)
    }
    // Proxy handlers moved to kind="data" with ProxyMessage
    { kind: "send", target: Some(target), data, .. } => {
      // When sending new data, encrypt it for the target
      let encrypted_data = match data {
        Binary(raw) => @msgpack.binary(encrypt_for_peer(target, raw))
        _ => data // Should be binary
      }
      let direct = Message::new(
        kind="data",
        from=msg.from,
        addr=msg.addr,
        data=encrypted_data,
        target~,
        encrypted=true,
      )
      add_pending_message(target, direct)
      // Find best relay peer
      let all_peers = get_global_peer_manager().get_all_peers()
      let mut best_relay : Connection? = None
      for peer in all_peers {
        let peer_id = peer.id
        if peer_id != target && peer_id != sender_addr && peer_id != local_addr {
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
          ignore(send_message(transport, relay_conn.remote_addr, request))
          ignore(send_message(transport, relay_conn.remote_addr, relay))
        }
        None => ()
      }
    }
    { kind: "data", data: Binary(raw_data), encrypted, .. } => {
      println(
        "DEBUG: Processing data message from \{msg.from}, encrypted=\{encrypted}",
      )
      // Decrypt data if encrypted
      let data_content = if encrypted {
        match decrypt_from_peer(msg.from, raw_data) {
          Some(decrypted) => {
            println("DEBUG: Decrypted message from \{msg.from}")
            decrypted
          }
          None => {
            println(
              "Failed to decrypt message from \{msg.from}, raw=\{raw_data}",
            )
            raw_data
          }
        }
      } else {
        raw_data
      }

      // Check if this is a ProxyMessage
      let is_proxy_msg = try {
        println("DEBUG: Attempting to decode ProxyMessage")
        let val = @msgpack.decode(data_content)
        match ProxyMessage::from_msgpack(val) {
          Some(proxy_msg) => {
            println("DEBUG: Spawning handle_proxy_message op=\{proxy_msg.op}")
            ignore(
              root.spawn(fn() {
                handle_proxy_message(root, id, local_addr, msg.from, proxy_msg)
              }),
            )
            true
          }
          None => {
            println("DEBUG: Not a ProxyMessage (decode success but mismatch)")
            false
          }
        }
      } catch {
        _ => {
          println("DEBUG: Not a ProxyMessage (decode failed)")
          false
        }
      }
      if !is_proxy_msg {
        // Execute scripts with received data and send back output
        root.spawn_bg(fn() {
          let content_str = @utf8.decode(data_content)
          match execute_script_handler(content_str) {
            Some(output) => {
              // Send response back to sender with script outputs
              let response_msg = Message::new(
                kind="data_response",
                from=id,
                addr=local_addr,
                relay=1,
                data=output.to_msgpack(),
                payload=msg.id,
              )
              // Add pending message instead of direct send
              add_pending_message(msg.from, response_msg)
              println(
                "DataResponse: queued id=\{response_msg.id} correlation=\{msg.id} to=\{msg.from}",
              )
            }
            None =>
              println("No scripts configured, received data: \{data_content}")
          }
        })
      }
    }
    { kind: "data_response", data: response_data, payload: correlation_id, .. } => {
      // Handle response from script execution
      println("Received script response from \{msg.from}:")
      println(response_data)

      // If this is a response to a pending request, resolve it
      match correlation_id {
        Some(id) => {
          println("DataResponse: resolve correlation=\{id} from=\{msg.from}")
          // Try to convert response to JSON string
          match response_data {
            Array(arr) => {
              let strings = []
              for v in arr {
                if v is String(s) {
                  strings.push(s)
                }
              }
              resolve_request(
                id,
                {},
                @utf8.encode(strings.to_json().stringify()),
              )
            }
            _ =>
              resolve_request(
                id,
                {},
                @utf8.encode(response_data.to_string().unwrap_or("error")),
              )
          }
        }
        None => println("DataResponse: missing correlation from=\{msg.from}")
      }
    }
    { kind: "sync", data: Array(conn_entries), .. } => {
      // Handle connection update from peer
      // Collect direct neighbors of the sender to update their connections list
      let sender_connections : Array[PeerConnectionInfo] = []

      // Parse connection entry: [peer_id, remote_addr, relay, public_key, latency, bandwidth, packet_loss]
      for entry in conn_entries {
        match SyncConnection::from_msgpack(entry) {
          Some(sync_conn) => {
            let peer_id = sync_conn.peer_id
            let remote_addr = sync_conn.remote_addr
            let relay_depth = sync_conn.relay
            let pk = sync_conn.public_key

            // If relay_depth is 1, it's a direct neighbor of the sender
            if relay_depth == 1 && peer_id != msg.from {
              sender_connections.push(PeerConnectionInfo::{
                peer_id,
                latency_ms: sync_conn.latency_ms,
                bandwidth_mbps: sync_conn.bandwidth_mbps,
                packet_loss_rate: sync_conn.packet_loss_rate,
                id: sync_conn.id,
                local_addr: sync_conn.local_addr,
                remote_addr: sync_conn.remote_addr,
                state: match sync_conn.state {
                  "Connected" => Connected
                  "Connecting" => Connecting
                  "Init" => Init
                  "Failed" => Failed
                  _ => Disconnected
                },
                last_seen: sync_conn.last_seen,
                quality: sync_conn.quality,
                relay: sync_conn.relay,
                metadata: sync_conn.metadata,
                latency_history: sync_conn.latency_history,
                packets_sent: sync_conn.packets_sent,
                packets_lost: sync_conn.packets_lost,
                bytes_sent: sync_conn.bytes_sent,
                bytes_received: sync_conn.bytes_received,
                last_ping_time: sync_conn.last_ping_time,
              })
            }

            // If the peer is not me
            if peer_id != id {
              // Update Routing Table
              // We learned that 'peer_id' is reachable via 'msg.from' with hops = relay_depth + 1
              // (Since relay_depth is the distance from msg.from to peer_id)
              let new_hops = relay_depth + 1
              update_global_peer_manager(fn(manager) {
                manager.update_route(peer_id, msg.from, new_hops)
              })

              // Add discovered address to known peers for potential direct connection
              if remote_addr != "routed" && !remote_addr.has_prefix("0.0.0.0:") {
                add_known_peer(remote_addr)
              }

              // Also compute shared secret if we have the PK
              compute_and_store_shared_secret(peer_id, pk)

              // Ensure peer exists in manager (even if only known via route)
              match get_global_peer_manager().get_peer(peer_id) {
                None => {
                  let addresses = if remote_addr != "routed" &&
                    !remote_addr.has_prefix("0.0.0.0:") {
                    [remote_addr]
                  } else {
                    []
                  }
                  let peer_node = PeerNode::new(
                    id=peer_id,
                    version=sync_conn.version,
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
                    !remote_addr.has_prefix("0.0.0.0:") {
                    update_global_peer_manager(fn(manager) {
                      manager.add_peer_address(peer_id, remote_addr)
                    })
                  }
              }

              // Create or update connection if it's a direct neighbor (for compatibility)
              // Only if remote_addr is not "routed" placeholder
              if peer_id == msg.from && remote_addr != "routed" {
                // Ensure remote_addr has protocol
                let safe_remote_addr = if remote_addr.contains("://") {
                  remote_addr
                } else {
                  sync_conn.protocol + "://" + remote_addr
                }
                let (_conn, _is_new, _is_new_peer) = handle_new_connection(
                  peer_id,
                  local_addr,
                  safe_remote_addr,
                  sync_conn.protocol,
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
          manager.update_peer_connections(msg.from, sender_connections)
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
  id : String,
) -> Unit {
  let local_addr = transport.protocol() + "://" + transport.local_addr()

  // Start reconnection background task
  root.spawn_bg(fn() { handle_reconnects(transport, local_addr, id) })
  // Start heartbeat/health check background task
  root.spawn_bg(fn() { handle_heartbeat(transport, local_addr, id) })
  // Start pending message sender background task
  root.spawn_bg(fn() { handle_pending_messages(transport, id) })
  // Start periodic connection update task
  root.spawn_bg(fn() { handle_periodic_updates(transport, id, local_addr) })

  // Listen loop
  transport.listen(
    root,
    fn(bytes, sender) {
      let sender = transport.protocol() + "://" + sender
      root.spawn_bg(fn() {
        handle_incoming_message(bytes, sender, id, local_addr, root, transport)
      })
    },
    fn(remote_addr) {
      let remote_addr = transport.protocol() + "://" + remote_addr
      let all_conns = get_global_connection_manager().get_all_connections()
      for conn in all_conns {
        if conn.remote_addr == remote_addr {
          update_global_connection_manager(fn(manager) {
            manager.update_connection_state(
              conn.id,
              ConnectionState::Disconnected,
            )
          })
          println("[disconnect]\t\{conn.peer_id}(\{remote_addr})")
          // println("Marked connection \{conn.id} as Disconnected")
        }
      }
    },
  )
}
