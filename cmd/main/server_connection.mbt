///|
/// Connection lifecycle — creating fresh peer connections and running the
/// reconnect loop that tries to promote relayed peers to direct connections.
///
/// - `handle_new_connection` reconciles an inbound `hello`/`sync` packet with
///   the peer/connection managers, upgrading relay depth on existing edges
///   and creating a new `Connection` if none exists yet.
/// - `handle_reconnects` runs forever on a 5s cadence and sends `hello`
///   probes to every peer we know but do not have a direct connection to.

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
      Some(existing) => { ..existing, version: info.version }
      None =>
        PeerNode::new(
          id=info.id,
          version=info.version,
          addresses=[remote_addr],
          metadata=Map([]),
        )
    }
    global_state.peer_manager = global_state.peer_manager.add_peer(peer_node)
    global_state.peer_manager = global_state.peer_manager.add_peer_address(
      info.id,
      remote_addr,
    )
    if info.peers is Some(peer_addrs) {
      let my_listeners = get_our_addresses(local_addr).map(fn(a) { a.address })
      for peer_addr_obj in peer_addrs {
        let addr = peer_addr_obj.address
        if addr.is_empty() || is_bind_all_address(addr) {
          continue
        }
        if my_listeners.contains(addr) {
          continue
        }
        global_state.peer_manager = global_state.peer_manager.add_peer_address(
          info.id,
          addr,
        )
      }
    }
  } else {
    // Only create peer if it doesn't exist yet
    match get_global_peer_manager().get_peer(actual_peer_id) {
      Some(_) =>
        global_state.peer_manager = global_state.peer_manager.add_peer_address(
          actual_peer_id, remote_addr,
        )
      None => {
        let peer_node = PeerNode::new(
          id=actual_peer_id,
          version=app_state.version,
          addresses=[remote_addr],
          metadata=Map([]),
        )
        global_state.peer_manager = global_state.peer_manager.add_peer(
          peer_node,
        )
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
      global_state.connection_manager = global_state.connection_manager.update_connection_relay(
        existing_conn.id,
        relay_depth,
      )
    }
    let upgraded_conn = if should_upgrade {
      existing_conn.update_relay(relay_depth)
    } else {
      existing_conn
    }
    let updated_conn = match port_tuple {
      Some((local_port, proto, remote_port)) => {
        let now = @env.now()
        global_state.connection_manager = global_state.connection_manager.update_connection_ports(
          existing_conn.id,
          local_port,
          proto,
          remote_port,
          now,
        )
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
  let my_id = get_config().id
  let new_conn = Connection::new(my_id, actual_peer_id)
  let mgr = global_state.connection_manager.add_connection(new_conn)
  global_state.connection_manager = mgr.update_connection_relay(
    new_conn.id,
    relay_depth,
  )
  log_debug(
    "DEBUG: handle_new_connection added peer=\{actual_peer_id} local=\{local_addr} remote=\{remote_addr}",
  )
  let conn = new_conn.update_relay(relay_depth)
  let updated_conn = match port_tuple {
    Some((local_port, proto, remote_port)) => {
      let now = @env.now()
      global_state.connection_manager = global_state.connection_manager.update_connection_ports(
        conn.id,
        local_port,
        proto,
        remote_port,
        now,
      )
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
  let transport_protocol = transport.protocol()
  let transport_protocol_type = transport.protocol_type()
  let reconnect_interval = 5000 // Fixed interval: 5s
  for ;; {
    // Sleep with fixed interval
    @async.sleep(reconnect_interval)
    let hello_msg = create_hello_message(
      peer_id,
      local_addr,
      1,
      peers=our_addresses,
    )

    // Build list of target addresses
    let targets : Map[String, String] = Map([])
    let peers = get_global_peer_manager().get_all_peers()
    for peer in peers {
      if has_direct_connection_for_protocol(
          peer.id,
          transport_protocol,
          transport_protocol_type,
        ) {
        continue
      }
      for addr_str in peer.addresses {
        let mut parsed : Address? = None
        try {
          parsed = Some(Address::parse(addr_str))
        } catch {
          _ => ()
        }
        if parsed is Some(addr) {
          if addr.protocol != transport_protocol_type {
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
            if a.protocol == transport_protocol_type {
              match peer_id_opt {
                Some(pid) => {
                  if has_direct_connection_for_protocol(
                      pid, transport_protocol, transport_protocol_type,
                    ) {
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
                None => if targets.get(addr) is None { targets[addr] = addr }
              }
            }
          None => if targets.get(addr) is None { targets[addr] = addr }
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
