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
}

///|
fn handle_hello_message(ctx : MessageContext) -> Unit {
  let msg = ctx.msg
  if ctx.should_skip_hello_callback {
    return
  }
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

  match get_global_peer_manager().get_peer(msg.source_id) {
    None => {
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
      match effective_pk_opt {
        Some(new_pk) =>
          if new_pk.length() > 0 {
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
              clear_shared_secret(msg.source_id)
            }
          }
        None => ()
      }
  }

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

  if msg.peers is Some(peer_addrs) {
    for peer_addr_obj in peer_addrs {
      let peer_url = peer_addr_obj.address
      if !is_bind_all_address(peer_url) && peer_url != ctx.local_addr {
        add_known_peer(peer_url)
      }
    }
  }

  if should_rebroadcast_hello(msg.source_id) {
    record_hello_time(msg.source_id)
    let known_peers = get_all_known_peers()
    let targets : Map[String, String] = {}
    for peer_url in known_peers {
      if peer_url != ctx.sender_addr && !is_bind_all_address(peer_url) {
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
    }
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
      let final_data = match ctx.msg.body {
        Binary(raw) => decode_binary_payload(raw)
        _ => ctx.msg.body
      }
      handle_data_response(correlation_id, final_data, ctx.msg.source_id)
    }
    None =>
      log_warn(
        "Response message missing payload correlation id from \{ctx.msg.source_id}",
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
  for conn in peer_conns {
    let current_time = @env.now()
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

///|
fn handle_sync_message(ctx : MessageContext) -> Unit {
  let msg = ctx.msg
  match msg.body {
    Array(conn_entries) => {
      let sender_connections : Array[PeerConnectionInfo] = []
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
        let (conn_val, pk_bytes) = match entry {
          Array(arr) =>
            if arr.length() >= 21 {
              let pk_val = arr[20]
              let pk = match pk_val {
                Binary(b) => b
                _ => []
              }
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
            if peer_id != ctx.my_id {
              let new_hops = relay_depth + 1
              log_debug(
                "DEBUG: update_route target=\{peer_id} via=\{msg.source_id} hops=\{new_hops}",
              )
              update_global_peer_manager(fn(manager) {
                manager.update_route(peer_id, msg.source_id, new_hops)
              })

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
                  if pk_bytes.length() > 0 {
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
      if !sender_connections.is_empty() {
        update_global_peer_manager(fn(manager) {
          manager.update_peer_connections(msg.source_id, sender_connections)
        })
      }
    }
    _ => ()
  }
}
