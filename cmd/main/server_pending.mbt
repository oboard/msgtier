///|
/// Pending-message pump — the background loop that retries queued messages
/// over every registered transport and routes them (or their relays) to the
/// right peers.
///
/// `handle_pending_messages` runs one queue per transport, waking on new
/// pending entries and periodic retry sweeps.  `process_pending_message`
/// handles the per-message work: skip if already sent, choose direct or
/// relayed delivery, mark acknowledged, and update retry state.

///|
async fn process_pending_message(
  transport : &Transport,
  my_id : String,
  local_addr : String,
  entry : PendingEntry,
  root : @async.TaskGroup[Unit],
  dispatcher : Ref[MessageDispatcher],
) -> Unit {
  let pending_msg = entry.msg
  // Double check if message is still pending (avoid race condition with removal)
  if !is_pending_message(pending_msg.id) {
    return
  }

  // Retry logic
  let now = @env.now()
  let retry_interval = 2000UL // 2 seconds
  if entry.last_attempt > 0UL && now - entry.last_attempt < retry_interval {
    return
  }
  if entry.retry_count > 5 {
    log_debug("Message \{pending_msg.id} exceeded max retries, removing")
    remove_pending_message(pending_msg) |> ignore
    return
  }
  if transport.protocol() == "udp" &&
    !(pending_msg.kind
    is ("ping"
    | "pong"
    | "hello"
    | "sync"
    | "file"
    | "image"
    | "http_proxy"
    | "response")) &&
    !(pending_msg.body is String(_)) {
    return
  }
  let cm = get_global_connection_manager()
  let mut sent = false
  let target_peer_ids = if pending_msg.is_broadcast() {
    get_global_peer_manager().get_all_peers().map(p => p.id)
  } else {
    match pending_msg.target_id {
      Some(target_id) => [target_id]
      None => get_global_peer_manager().get_all_peers().map(p => p.id)
    }
  }
  for target_peer_id in target_peer_ids {
    if entry.acked_peers.get(target_peer_id) == Some(true) {
      continue
    }
    // Handle loopback (send to self)
    if target_peer_id == my_id {
      // Attempt to remove message atomically (returns true if we removed it)
      // This prevents multiple transports from handling the same local message
      if remove_pending_message(pending_msg) {
        log_info("PendingMessage: handling local loopback id=\{pending_msg.id}")
        // Use spawn_bg to avoid blocking the pending loop
        root.spawn_bg(async fn() {
          handle_incoming_message(
            pending_msg.to_msgpack(),
            local_addr,
            my_id,
            local_addr,
            root,
            transport,
            dispatcher,
          )
        })
      }
      continue
    }
    if pending_msg.kind is ("response" | "http_proxy") &&
      transport.protocol() != "tcp" {
      let has_tcp_addr = pick_peer_address(target_peer_id, "tcp") is Some(_) ||
        pick_peer_lan_address(target_peer_id, "tcp") is Some(_)
      if has_tcp_addr {
        continue
      }
    }
    if transport.protocol() == "udp" &&
      !should_send_message(pending_msg.id, target_peer_id, "udp", 200UL) {
      continue
    }
    let target_connections = cm.get_peer_connections(target_peer_id)
    if target_connections.is_empty() {
      if pick_peer_lan_address(target_peer_id, transport.protocol())
        is Some(addr) {
        let target_addr = if addr.contains("://") {
          addr
        } else {
          transport.protocol() + "://" + addr
        }
        if !target_addr.is_empty() && target_addr != "routed" {
          let msg = pending_msg
          log_debug("PendingMessage: lan addr=\{target_addr} id=\{msg.id}")
          let success = send_message(transport, target_addr, msg)
          log_debug(
            "DEBUG: pending lan send protocol=\{transport.protocol()} addr=\{target_addr} id=\{msg.id} ok=\{success}",
          )
          if success {
            sent = true
            if transport.protocol() == "udp" {
              record_message_sent(pending_msg.id, target_peer_id, "udp")
            } else {
              mark_pending_message_attempted(
                pending_msg.id,
                target_peer_id,
                transport.protocol(),
              )
              |> ignore
            }
          }
        }
      }
      if sent {
        continue
      }
      // For broadcast messages, do not use unicast routing to avoid duplicates and type confusion
      if pending_msg.is_broadcast() {
        continue
      }
      // Check if we have a route for this peer
      match get_global_peer_manager().get_route(target_peer_id) {
        Some(route) => {
          // Try to relay
          log_debug(
            "DEBUG: pending relay to=\{target_peer_id} via=\{route.next_hop}",
          )
          // Relay message handles finding connection to next_hop for current transport
          let relayed = relay_message(
            transport, my_id, pending_msg, target_peer_id,
          )
          if relayed {
            sent = true
            if transport.protocol() == "udp" {
              record_message_sent(pending_msg.id, target_peer_id, "udp")
            } else {
              mark_pending_message_attempted(
                pending_msg.id,
                target_peer_id,
                transport.protocol(),
              )
              |> ignore
            }
          }
        }
        None =>
          log_debug(
            "DEBUG: pending no connections and no route protocol=\{transport.protocol()} target=\{target_peer_id} id=\{pending_msg.id}",
          )
      }
      continue
    }
    if pending_msg.kind == "sync" &&
      entry.sent_targets.get(target_peer_id) is Some(m) &&
      m.length() > 0 {
      continue
    }
    if entry.sent_targets.get(target_peer_id) is Some(m) &&
      m.contains(transport.protocol()) {
      continue
    }
    if transport.protocol() == "udp" &&
      !should_send_message(pending_msg.id, target_peer_id, "udp", 200UL) {
      continue
    }
    // Collect candidate addresses from both active connections and PeerManager
    let candidates : Array[String] = []
    let seen_candidates : Map[String, Bool] = Map([])

    // 1. Add addresses from active connections (prioritized)
    for conn in target_connections {
      if conn.relay == 1 {
        for addr, _ in conn.address_stats {
          if addr.has_prefix(transport.protocol() + "://") {
            if !seen_candidates.contains(addr) {
              candidates.push(addr)
              seen_candidates[addr] = true
            }
          }
        }
      }
    }
    if get_global_peer_manager().get_peer(target_peer_id) is Some(peer) {
      let lan_addrs : Array[String] = []
      let wan_addrs : Array[String] = []
      for addr_str in peer.addresses {
        if addr_str.is_empty() ||
          addr_str == "routed" ||
          is_bind_all_address(addr_str) {
          continue
        }
        let mut parsed : Address? = None
        try {
          parsed = Some(Address::parse(addr_str))
        } catch {
          _ => ()
        }
        if parsed is Some(addr) &&
          addr.protocol.to_string() == transport.protocol() {
          let host = extract_host(addr_str)
          let full_addr = if addr_str.contains("://") {
            addr_str
          } else {
            transport.protocol() + "://" + addr_str
          }
          if !seen_candidates.contains(full_addr) {
            if is_private(host) || is_loopback(host) {
              lan_addrs.push(full_addr)
            } else {
              wan_addrs.push(full_addr)
            }
            seen_candidates[full_addr] = true
          }
        }
      }
      // Append LAN then WAN addresses from PeerManager to candidates
      for addr in lan_addrs {
        candidates.push(addr)
      }
      for addr in wan_addrs {
        candidates.push(addr)
      }
    }

    // Send to candidates
    for target_addr in candidates {
      let msg = pending_msg
      log_debug("PendingMessage: direct addr=\{target_addr} id=\{msg.id}")
      let success = send_message(transport, target_addr, msg)
      log_debug(
        "DEBUG: pending send protocol=\{transport.protocol()} addr=\{target_addr} id=\{msg.id} ok=\{success}",
      )
      if success {
        sent = true
        if transport.protocol() == "udp" {
          record_message_sent(pending_msg.id, target_peer_id, "udp")
        }
        break
      }
    }
    if !sent && !pending_msg.is_broadcast() {
      let relayed = relay_message(transport, my_id, pending_msg, target_peer_id)
      if relayed {
        sent = true
        if transport.protocol() == "udp" {
          record_message_sent(pending_msg.id, target_peer_id, "udp")
        }
      }
    }
    if sent && transport.protocol() != "udp" {
      log_debug(
        "DEBUG: pending mark sent id=\{pending_msg.id} protocol=\{transport.protocol()}",
      )
      mark_pending_message_attempted(
        pending_msg.id,
        target_peer_id,
        transport.protocol(),
      )
      |> ignore
    } else if target_connections.length() > 0 {
      // If we have connections but failed to send on this specific transport
      log_debug(
        "DEBUG: pending failed to send on any connection protocol=\{transport.protocol()} target=\{target_peer_id} id=\{pending_msg.id}",
      )
    }
  }
  update_pending_message_state(pending_msg.id, entry.retry_count + 1, now)
}

///|
async fn handle_pending_messages(
  root : @async.TaskGroup[Unit],
  transport : &Transport,
  my_id : String,
  dispatcher : Ref[MessageDispatcher],
) -> Unit {
  let protocol_prefix = transport.protocol() + "://"
  let local_addr = transport.protocol() + "://" + transport.local_addr()
  log_debug(
    "DEBUG: handle_pending_messages start protocol=\{transport.protocol()} prefix=\{protocol_prefix}",
  )
  let queue = @aqueue.Queue(kind=Unbounded)
  let in_queue : @set.Set[String] = @set.Set([], capacity=0)
  let mut pending_generation = get_pending_generation()
  root.spawn_bg(async fn() {
    for ;; {
      let entry : PendingEntry = queue.get()
      // Spawn a new task for each message to avoid head-of-line blocking
      root.spawn_bg(async fn() {
        process_pending_message(
          transport, my_id, local_addr, entry, root, dispatcher,
        ) catch {
          e => log_warn("Pending message processing error: \{e}")
        }
        in_queue.remove(entry.msg.id)
      })
    }
  })
  for ;; {
    // Wake immediately for new messages, but still sweep periodically for retries/timeouts.
    pending_generation = wait_for_pending_change(pending_generation, 100)
    let now = @env.now()
    let retry_interval = 2000UL
    // Only take messages we can handle:
    // 1. Specific protocol match (e.g. tcp://...)
    // 2. No protocol (peer ID) - we try to route these
    let pending = take_pending_messages(fn(entry) {
      entry.last_attempt == 0UL || now - entry.last_attempt >= retry_interval
    })
    if pending.is_empty() {
      continue
    }
    log_debug(
      "DEBUG: pending batch protocol=\{transport.protocol()} count=\{pending.length()}",
    )

    // Process each pending message
    for entry in pending {
      if in_queue.contains(entry.msg.id) {
        continue
      }
      in_queue.add(entry.msg.id)
      queue.put(entry)
    }
  }
}
