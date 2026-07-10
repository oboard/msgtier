///|
/// Inbound-message decoder and pipeline entry point.
///
/// `handle_incoming_message` is the single funnel every transport pushes
/// received bytes into.  It parses the length-prefixed msgpack + optional
/// attachment, decrypts, ACKs, deduplicates, updates connection state,
/// forwards for relay/broadcast, and finally hands the built `Message` to
/// the dispatcher registry.

///|
async fn handle_incoming_message(
  bytes : Bytes,
  sender_addr : String,
  id : String,
  local_addr : String,
  root : @async.TaskGroup[Unit],
  transport : &Transport,
  dispatcher : Ref[MessageDispatcher],
) -> Unit noraise {
  if bytes.length() < 4 {
    log_warn("Received message too short: \{bytes.length()} bytes")
    return
  }

  // Parse MsgPack length
  let msgpack_len = (bytes[0].to_int() << 24) |
    (bytes[1].to_int() << 16) |
    (bytes[2].to_int() << 8) |
    bytes[3].to_int()
  log_debug(
    "DEBUG: incoming bytes=\{bytes.length()} msgpack_len=\{msgpack_len}",
  )
  let (msgpack_bytes, attachment_bytes) = if msgpack_len < 0 ||
    msgpack_len > bytes.length() - 4 {
    log_debug(
      "Invalid MsgPack length prefix: \{msgpack_len} (total: \{bytes.length()}). Attempting raw decode.",
    )
    (bytes, None)
  } else {
    let mb = slice_bytes(bytes, 4, 4 + msgpack_len)
    let ab = if 4 + msgpack_len < bytes.length() {
      Some(slice_bytes(bytes, 4 + msgpack_len, bytes.length()))
    } else {
      None
    }
    (mb, ab)
  }
  let msgpack_value = @msgpack.decode(msgpack_bytes) catch {
    e => {
      let error_msg = e.to_string()
      log_debug(
        "DEBUG: Msgpack decode error - \{error_msg}, sender: \{sender_addr}, bytes: \{msgpack_bytes.length()}",
      )
      return
    }
  }
  let msg_temp = Message::from_msgpack(msgpack_value) catch {
    _ => {
      log_warn(
        "Failed to decode message: \{msgpack_value.to_json().stringify()}",
      )
      return
    }
  }
  let msg = { ..msg_temp, attachment: attachment_bytes }

  // Skip messages from self, unless target is self
  if msg.source_id == id && msg.target_id != Some(id) {
    return
  }
  let msg = decrypt_message_body(id, msg)
  guard msg is Some(msg) else { return }
  // Fast path: port_forward_data skips connection tracking, dedup, WS emit, and
  // logging — all designed for control messages, not high-frequency data chunks.
  // Relay nodes still forward correctly; TCP seq numbers handle any duplicates.
  if msg.kind == "port_forward_data" {
    if msg.target_id == Some(id) {
      dispatch_message(dispatcher, MessageContext::{
        root,
        transport,
        local_addr,
        sender_addr,
        my_id: id,
        msg,
        should_skip_hello_callback: false,
      })
    } else if msg.target_id is Some(target_peer_id) {
      ignore(
        relay_message(transport, id, msg, target_peer_id, allow_queueing=true),
      )
    }
    return
  }
  let is_broadcast = msg.is_broadcast()
  let is_unicast_to_me = match msg.target_id {
    Some(tid) => tid == id
    None => false
  }
  let should_ack = !(msg.kind
    is ("ack" | "ping" | "pong" | "hello" | "port_forward_data" | "sync")) &&
    (is_unicast_to_me || is_broadcast)
  if should_ack {
    let ack_msg = if is_broadcast {
      Message(
        kind="ack",
        source_id=id,
        source_addr=local_addr,
        // No target_id implies broadcast
        payload=msg.id,
        encrypted=msg.encrypted,
      )
    } else {
      Message(
        kind="ack",
        source_id=id,
        source_addr=local_addr,
        target_id=msg.source_id,
        payload=msg.id,
        encrypted=msg.encrypted,
      )
    }
    if is_broadcast {
      add_pending_message(ack_msg)
    } else {
      ignore(send_message(transport, sender_addr, ack_msg))
    }
  }
  if msg.kind != "ack" {
    if check_and_mark_received(msg.id, msg.timestamp) {
      return
    }
  }
  if !msg.encrypted {
    root.spawn_bg(async fn() { emit_ws_message(msg) })
  }
  // Logger
  log_info(
    "[\{msg.kind}]\t\{msg.source_id}(\{sender_addr})" +
    (if msg.relay > 1 { " relay=\{msg.relay}" } else { "" }),
  )
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
                sender_addr[:idx].to_owned()
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
    { kind: "hello", .. } => {
      // Get our own listening addresses to prevent attributing them to peers
      let my_listeners = get_our_addresses(local_addr).map(fn(a) { a.address })
      let addrs : Array[NetworkAddress] = []

      // Helper to add unique non-self address
      let add_if_valid = (addr : String) => {
        if !my_listeners.contains(addr) &&
          !addrs.iter().any(a => a.address == addr) {
          addrs.push(NetworkAddress::{ address: addr })
        }
      }
      add_if_valid(sender_addr)
      if !connectable_addr.is_empty() {
        add_if_valid(connectable_addr)
      }
      Some(NetworkDiscoveryInfo::{
        id: msg.source_id,
        version: match msg.version {
          Some(v) => v
          None => app_state.version
        },
        addresses: addrs,
        peers: msg.peers,
      })
    }
    _ => None
  }

  // Always handle connection, even if peer_info is None
  // Use the message's relay count as the hop depth for this connection
  // msg.relay already indicates how many hops the message took to reach us
  let relay_depth_to_use = msg.relay
  let effective_addr = if sender_addr.contains("://") {
    sender_addr
  } else {
    transport.protocol() + "://" + sender_addr
  }
  learn_route_from_relayed_message(
    id,
    msg.source_id,
    effective_addr,
    relay_depth_to_use,
  )
  let (conn, is_new_connection, is_new_peer) = handle_new_connection(
    msg.source_id,
    local_addr,
    effective_addr,
    transport.protocol(),
    peer_info?,
    relay_depth=relay_depth_to_use,
  )
  log_debug(
    "DEBUG: connection handled peer=\{msg.source_id} local=\{local_addr} remote=\{effective_addr} protocol=\{transport.protocol()} new=\{is_new_connection}",
  )
  // let now = @env.now()
  // let diff = if now >= conn.last_seen { now - conn.last_seen } else { 0UL }

  let should_skip_hello_callback = if msg.kind == "hello" {
    let hello_key = msg.source_id + "|" + sender_addr
    check_and_mark_hello(hello_key, 5000UL)
  } else {
    false
  }

  // Reply to hello if it's a new connection or new peer (key update), to ensure bidirectional key exchange.
  if (is_new_connection || is_new_peer) &&
    msg.kind == "hello" &&
    !should_skip_hello_callback {
    let our_addresses = get_our_addresses(local_addr)
    let hello_msg = create_hello_message(id, local_addr, 1, peers=our_addresses)
    let target_addr = effective_addr
    let target_addr_full = if target_addr.contains("://") {
      target_addr
    } else {
      transport.protocol() + "://" + target_addr
    }
    // Don't log here to avoid spam, debug log is enough
    log_debug(
      "DEBUG: Replying hello to \{target_addr_full} (new_conn=\{is_new_connection}, new_peer=\{is_new_peer})",
    )
    ignore(send_message(transport, target_addr_full, hello_msg))
  }

  // Track bytes received
  global_state.connection_manager = global_state.connection_manager.update_connection_bytes(
    conn.id,
    0UL,
    bytes.length().to_uint64(),
  )

  // Update last_seen timestamp
  let timestamp = @env.now()
  global_state.connection_manager = global_state.connection_manager.update_connection_last_seen(
    conn.id,
    timestamp,
  )

  // Update address stats to mark this address as active and valid for sending responses
  // This ensures pick_peer_address will consider this address as a "good candidate"
  let timestamp = @env.now()
  global_state.connection_manager = global_state.connection_manager.update_connection_address_pong(
    conn.id,
    effective_addr,
    timestamp,
  )

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
      // Push our current port scan to the newly-connected peer immediately, so
      // they don't have to wait for the next 500 ms poll tick — or, in the
      // worst case, the next 30 s full scan tick — to learn what we're
      // exposing. `snapshot_new_peers` is idempotent per-peer, so calling it
      // here does not cause duplicate sends when the poll loop also fires.
      snapshot_new_peers() catch {
        _ => ()
      }
    } else {
      log_debug(
        "DEBUG: secondary connection established peer=\{msg.source_id} count=\{peer_conns.length()} - skipping broadcast_sync",
      )
    }
  }

  // Handle message relaying: if target is set and we're not the target, forward it
  // and stop — relay nodes must NOT dispatch the message locally.
  if msg.target_id is Some(target_peer_id) &&
    !(app_state.config is Some({ id, .. }) && id == target_peer_id) {
    // Message is for someone else: relay and stop processing here.
    // Without this early return every intermediate hop would also dispatch
    // the message (e.g. execute scripts, handle http_proxy requests, etc.)
    // that were only intended for the final target.
    ignore(
      relay_message(transport, id, msg, target_peer_id, allow_queueing=true),
    )
    return
  }

  // Handle broadcast forwarding: if broadcast is true, forward to all peers (except sender)
  if msg.is_broadcast() &&
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
          target_id: None,
        }
        ignore(send_message(transport, peer_addr, broadcast_msg))
        // println("[broadcast]\t\{msg.from}(\{sender_addr}) -> \{peer_addr}")
      }
    }
  }
  if !(msg.kind is ("ping" | "pong")) &&
    !(msg.kind == "hello" && should_skip_hello_callback) {
    log_debug("Received \{msg.kind} from \{msg.source_id}")
  }
  let ctx = MessageContext::{
    root,
    transport,
    local_addr,
    sender_addr,
    my_id: id,
    msg,
    should_skip_hello_callback,
  }
  dispatch_message(dispatcher, ctx)
}
