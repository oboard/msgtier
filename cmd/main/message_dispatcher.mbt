///|
struct MessageContext {
  root : @async.TaskGroup[Unit]
  transport : &Transport
  local_addr : String
  sender_addr : String
  my_id : String
  msg : Message
  should_skip_hello_callback : Bool
}

///|
struct MessageDispatcher {
  handlers : Map[String, (MessageContext) -> Unit]
}

///|
struct MessagePlugin {
  register : (MessageDispatcher) -> Unit
}

///|
fn MessageDispatcher::new() -> MessageDispatcher {
  { handlers: {} }
}

///|
fn MessageDispatcher::register(
  self : MessageDispatcher,
  kind : String,
  handler : (MessageContext) -> Unit,
) -> Unit {
  let handlers = self.handlers
  handlers[kind] = handler
}

///|
fn dispatch_message(
  dispatcher : Ref[MessageDispatcher],
  ctx : MessageContext,
) -> Unit {
  match dispatcher.val.handlers.get(ctx.msg.kind) {
    Some(handler) => handler(ctx)
    None => ()
  }
}

///|
fn build_message_dispatcher() -> MessageDispatcher {
  build_message_dispatcher_with_plugins(get_default_plugins())
}

///|
fn build_message_dispatcher_with_plugins(
  plugins : Array[MessagePlugin],
) -> MessageDispatcher {
  let dispatcher = MessageDispatcher::new()
  for plugin in plugins {
    (plugin.register)(dispatcher)
  }
  dispatcher
}

///|
fn get_default_plugins() -> Array[MessagePlugin] {
  [core_message_plugin(), script_message_plugin(), object_message_plugin()]
}

///|
fn core_message_plugin() -> MessagePlugin {
  { register: register_core_handlers }
}

///|
fn register_core_handlers(dispatcher : MessageDispatcher) -> Unit {
  dispatcher.register("hello", handle_hello_message)
  dispatcher.register("text", handle_text_message)
  dispatcher.register("response", handle_response_message)
  dispatcher.register("ping", handle_ping_message)
  dispatcher.register("pong", handle_pong_message)
  dispatcher.register("sync", handle_sync_message)
  dispatcher.register("ack", handle_ack_message)
}

///|
fn normalize_sender_addr(ctx : MessageContext) -> String {
  if ctx.sender_addr.contains("://") {
    ctx.sender_addr
  } else {
    ctx.transport.protocol() + "://" + ctx.sender_addr
  }
}

///|
fn verify_peer_secret(msg : Message) -> Bool {
  match global_config.val {
    Some(config) => {
      let our_secret_hash = bytes_to_hex(hash_secret(config.secret))
      match msg.secret_hash {
        Some(peer_secret_hash) =>
          if peer_secret_hash == our_secret_hash {
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
}

///|
fn ensure_peer_exists_from_hello(ctx : MessageContext) -> Unit {
  let msg = ctx.msg
  match get_global_peer_manager().get_peer(msg.source_id) {
    Some(_) => ()
    None => {
      let peer_node = PeerNode::new(
        id=msg.source_id,
        version=VERSION,
        addresses=if msg.source_addr is Some(addr) { [addr] } else { [] },
        metadata={},
      )
      global_state.peer_manager = global_state.peer_manager.add_peer(peer_node)
    }
  }
}

///|
fn collect_sender_addrs_from_hello(
  msg : Message,
  local_addr : String,
) -> Array[String] {
  let sender_addrs : Array[String] = []
  if msg.peers is Some(peer_addrs) {
    for peer_addr_obj in peer_addrs {
      let peer_url = peer_addr_obj.address
      if !is_bind_all_address(peer_url) && peer_url != local_addr {
        add_known_peer(peer_url)
        sender_addrs.push(peer_url)
      }
    }
  }
  sender_addrs
}

///|
fn try_probe_sender_addrs(
  ctx : MessageContext,
  sender_addrs : Array[String],
) -> Unit {
  if sender_addrs.is_empty() {
    return
  }
  for transport in get_registered_transports() {
    if has_direct_connection_for_protocol(
        ctx.msg.source_id,
        transport.protocol(),
        transport.protocol_type(),
      ) {
      continue
    }
    let local_addr = transport.protocol() + "://" + transport.local_addr()
    let our_addresses = get_our_addresses(local_addr)
    let hello_msg = create_hello_message(
      get_config().id,
      local_addr,
      1,
      peers=our_addresses,
    )
    for peer_url in sender_addrs {
      let mut parsed : Address? = None
      try {
        parsed = Some(Address::parse(peer_url))
      } catch {
        _ => ()
      }
      match parsed {
        Some(addr) =>
          if addr.protocol == transport.protocol_type() {
            ctx.root.spawn_bg(async fn() {
              ignore(send_message(transport, peer_url, hello_msg))
            })
            break
          }
        None => ()
      }
    }
  }
}

///|
fn collect_rebroadcast_targets(ctx : MessageContext) -> Map[String, String] {
  let known_peers = get_all_known_peers()
  let targets : Map[String, String] = {}
  for peer_url in known_peers {
    if peer_url == ctx.sender_addr || is_bind_all_address(peer_url) {
      continue
    }
    let peer_id_opt = get_global_peer_manager().get_peer_id_by_address(peer_url)
    let mut parsed : Address? = None
    try {
      parsed = Some(Address::parse(peer_url))
    } catch {
      _ => ()
    }
    match parsed {
      Some(a) =>
        if a.protocol == ctx.transport.protocol_type() {
          let key = match peer_id_opt {
            Some(pid) =>
              pid + "|" + a.protocol.to_string() + "|" + a.port.to_string()
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
  targets
}

///|
fn handle_hello_message(ctx : MessageContext) -> Unit {
  let msg = ctx.msg
  if ctx.should_skip_hello_callback {
    return
  }
  if !verify_peer_secret(msg) {
    return
  }

  ensure_peer_exists_from_hello(ctx)

  let sender_addrs = collect_sender_addrs_from_hello(msg, ctx.local_addr)
  try_probe_sender_addrs(ctx, sender_addrs)

  if should_rebroadcast_hello(msg.source_id) {
    record_hello_time(msg.source_id)
    let targets = collect_rebroadcast_targets(ctx)
    for _, peer_url in targets {
      ctx.root.spawn_bg(async fn() {
        ignore(send_message(ctx.transport, peer_url, msg))
      })
    }
  }
}

///|
fn handle_text_message(ctx : MessageContext) -> Unit {
  match ctx.msg.body {
    String(text) => {
      log_info("Received text message: \{text}")
      send_response_message(
        ctx.transport,
        ctx.root,
        ctx.my_id,
        ctx.sender_addr,
        ctx.msg.source_id,
        ctx.msg.payload.unwrap_or(ctx.msg.id),
        @msgpack.string(text),
      )
    }
    _ => ()
  }
}

///|
fn handle_response_message(ctx : MessageContext) -> Unit {
  match ctx.msg.payload {
    Some(correlation_id) => {
      log_debug(
        "ResponseMessage: recv msg_id=\{ctx.msg.id} correlation=\{correlation_id} from=\{ctx.msg.source_id}",
      )
      let final_data = match ctx.msg.body {
        Binary(raw) => decode_binary_payload(raw)
        _ => ctx.msg.body
      }
      handle_data_response(
        correlation_id,
        final_data,
        ctx.msg.attachment,
        ctx.msg.source_id,
      )
      ignore(remove_pending_message_by_id(correlation_id))
    }
    None =>
      log_warn(
        "Response message missing payload correlation id from \{ctx.msg.source_id}, msg_id=\{ctx.msg.id}",
      )
  }
}

///|
fn handle_ping_message(ctx : MessageContext) -> Unit {
  let reply = Message::new(
    kind="pong",
    source_id=ctx.my_id,
    source_addr=ctx.local_addr,
    target_id=ctx.msg.source_id,
  )
  ctx.root.spawn_bg(async fn() {
    let ok = send_message(ctx.transport, ctx.sender_addr, reply)
    log_debug(
      "DEBUG: pong send protocol=\{ctx.transport.protocol()} to=\{ctx.sender_addr} ok=\{ok}",
    )
  })
}

///|
fn handle_pong_message(ctx : MessageContext) -> Unit {
  let peer_id = ctx.msg.source_id
  log_debug(
    "DEBUG: pong recv protocol=\{ctx.transport.protocol()} from=\{ctx.sender_addr} peer=\{peer_id}",
  )
  let peer_conns = get_global_connection_manager().get_peer_connections(peer_id)
  let addr_key = normalize_sender_addr(ctx)
  for conn in peer_conns {
    let current_time = @env.now()
    match conn.last_ping_time {
      Some(ping_time) => {
        let rtt_ms = (current_time - ping_time).to_int()
        global_state.connection_manager = global_state.connection_manager.update_connection_latency(
          conn.id,
          rtt_ms,
        )
      }
      None => ()
    }
    global_state.connection_manager = global_state.connection_manager.update_connection_address_pong(
      conn.id,
      addr_key,
      current_time,
    )
    global_state.connection_manager = global_state.connection_manager.update_connection_pong_time(
      conn.id,
      Some(current_time),
    )
    global_state.connection_manager = global_state.connection_manager.update_connection_last_seen(
      conn.id,
      current_time,
    )
  }
}

///|
fn handle_ack_message(ctx : MessageContext) -> Unit {
  match ctx.msg.payload {
    Some(id) => mark_pending_message_acked(id, ctx.msg.source_id)
    None => ()
  }
}

///|
fn connection_to_peer_info(conn : Connection) -> PeerConnectionInfo {
  PeerConnectionInfo::{
    peer_id: conn.peer_id,
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
  }
}

///|
fn ensure_route_and_peer(
  my_id : String,
  source_id : String,
  conn : Connection,
) -> Unit {
  let peer_id = conn.peer_id
  if peer_id == my_id {
    return
  }
  let new_hops = conn.relay + 1
  log_debug(
    "DEBUG: update_route target=\{peer_id} via=\{source_id} hops=\{new_hops}",
  )
  global_state.peer_manager = global_state.peer_manager.update_route(
    peer_id, source_id, new_hops,
  )

  match get_global_peer_manager().get_peer(peer_id) {
    Some(_) => ()
    None => {
      let peer_node = PeerNode::new(
        id=peer_id,
        version=conn.version,
        addresses=[],
        metadata={},
      )
      global_state.peer_manager = global_state.peer_manager.add_peer(peer_node)
    }
  }
}

///|
fn handle_sync_message(ctx : MessageContext) -> Unit {
  let msg = ctx.msg
  match msg.body {
    Array(conn_entries) => {
      let sender_connections : Array[PeerConnectionInfo] = []
      let mut source_metadata : Map[String, String]? = None

      if msg.peers is Some(peer_addrs) {
        let known_list : Array[String] = []
        for peer_addr_obj in peer_addrs {
          if peer_addr_obj.address != ctx.local_addr {
            known_list.push(peer_addr_obj.address)
          }
        }
        add_known_peers(known_list)
      }

      for entry in conn_entries {
        match Connection::from_msgpack(entry) {
          Some(conn) => {
            log_debug(
              "DEBUG: sync entry peer=\{conn.peer_id} relay=\{conn.relay} source=\{msg.source_id}",
            )

            if source_metadata is None {
              match conn.metadata {
                Some(metadata) => source_metadata = Some(metadata)
                None => ()
              }
            }

            if conn.relay == 1 && conn.peer_id != msg.source_id {
              sender_connections.push(connection_to_peer_info(conn))
            }

            ensure_route_and_peer(ctx.my_id, msg.source_id, conn)
          }
          None => ()
        }
      }

      if !sender_connections.is_empty() {
        global_state.peer_manager = global_state.peer_manager.update_peer_connections(
          msg.source_id,
          sender_connections,
        )
      }

      match source_metadata {
        Some(metadata) =>
          global_state.peer_manager = global_state.peer_manager.update_peer_metadata(
            msg.source_id,
            metadata,
          )
        None => ()
      }
    }
    _ => ()
  }
}
