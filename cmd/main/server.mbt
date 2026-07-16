///|
struct ServerState {
  connection_timeout_ms : UInt64
  mut last_sync_broadcast_time : UInt64
  received_message_cache : Map[String, UInt64]
}

///|
let server_state : ServerState = {
  connection_timeout_ms: 60000,
  last_sync_broadcast_time: 0,
  received_message_cache: Map([]),
}

///|
fn check_and_mark_received(id : String, timestamp : UInt64) -> Bool {
  let now = @env.now()
  if now > timestamp && now - timestamp > 30000 {
    return true
  }
  let cache = server_state.received_message_cache
  if cache.contains(id) {
    return true
  }
  cache[id] = now
  false
}

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
  if (local_port, remote_port, proto) is (Some(lp), Some(rp), Some(p)) {
    Some((lp, p, rp))
  } else {
    None
  }
}

///|
fn has_direct_connection_for_protocol(
  peer_id : String,
  protocol : String,
  protocol_type : Protocol,
) -> Bool {
  get_global_connection_manager()
  .get_peer_connections(peer_id)
  .any(conn => {
    if conn.relay != 1 {
      return false
    }
    if conn.ports.any(fn(p) { p.protocol == protocol_type }) {
      return true
    }
    for addr, _ in conn.address_stats {
      if addr.has_prefix(protocol + "://") {
        return true
      }
    }
    false
  })
}

///|
fn learn_route_from_relayed_message(
  my_id : String,
  source_id : String,
  sender_addr : String,
  relay_depth : Int,
) -> Unit {
  if relay_depth <= 1 || source_id == my_id {
    return
  }
  let effective_addr = if sender_addr.contains("://") {
    sender_addr
  } else {
    "tcp://" + sender_addr
  }
  guard get_global_peer_manager().get_peer_id_by_address(effective_addr)
    is Some(next_hop) else {
    return
  }
  if next_hop == my_id || next_hop == source_id {
    return
  }
  log_debug(
    "DEBUG: learn relay route target=\{source_id} via=\{next_hop} hops=\{relay_depth}",
  )
  global_state.peer_manager = global_state.peer_manager.update_route(
    source_id, next_hop, relay_depth,
  )
}

///|
async fn start_listener_service(
  root : @async.TaskGroup[Unit],
  child : @async.TaskGroup[Unit],
  transport : &Transport,
  my_id : String,
) -> Unit {
  let dispatcher = Ref(build_message_dispatcher())
  let local_addr = transport.protocol() + "://" + transport.local_addr()
  register_transport(transport)
  log_debug(
    "DEBUG: start_listener_service protocol=\{transport.protocol()} local=\{local_addr} id=\{my_id}",
  )

  // Transport-tied tasks: cancelled when transport closes
  child.spawn_bg(() => handle_reconnects(transport, local_addr, my_id))
  child.spawn_bg(() => handle_heartbeat(transport, local_addr, my_id))
  child.spawn_bg(() => {
    handle_pending_messages(root, transport, my_id, dispatcher)
  })
  child.spawn_bg(() => handle_periodic_updates(my_id, local_addr))

  // Register raw port-forward data handler — bypasses the message layer entirely
  // for high-frequency data frames, avoiding msgpack encode/decode and dispatch overhead.
  transport.set_raw_data_handler(fn(connection_id, seq, data) {
    dispatch_raw_port_forward_data(root, connection_id, seq, data)
  })

  // Listen loop
  transport.listen(
    root,
    fn(bytes, sender) {
      let sender = transport.protocol() + "://" + sender
      root.spawn_bg(async fn() {
        handle_incoming_message(
          bytes, sender, my_id, local_addr, root, transport, dispatcher,
        )
      })
    },
    fn(remote_addr) {
      let remote_addr = transport.protocol() + "://" + remote_addr
      if get_global_peer_manager().get_peer_id_by_address(remote_addr)
        is Some(peer_id) {
        let conns = get_global_connection_manager().get_peer_connections(
          peer_id,
        )
        for conn in conns {
          if conn.relay == 1 {
            global_state.connection_manager = global_state.connection_manager.remove_connection(
              conn.id,
            )
            log_warn("[disconnect]\t\{conn.peer_id}(\{remote_addr})")
          }
        }
      }
    },
  )
}
