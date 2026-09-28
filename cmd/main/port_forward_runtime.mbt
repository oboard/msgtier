///|
fn close_port_forward_udp_client(client : @socket.UdpClient) -> Unit {
  client.close()
}

///|
// Try to send port-forward data via the raw transport fast path.
// Falls back to the message path if no matching transport supports raw frames.
async fn send_raw_port_forward_via(
  route_protocol : String,
  route_addr : String,
  connection_id : String,
  seq : Int,
  data : Bytes,
) -> Bool {
  if route_protocol == "" || route_addr == "" {
    return false
  }
  for transport in get_registered_transports() {
    if transport.protocol() == route_protocol {
      return transport.send_raw_port_forward(
        route_addr, connection_id, seq, data,
      )
    }
  }
  false
}

///|
async fn send_port_forward_tcp_chunks(
  endpoint : PortForwardTcpEndpoint,
  data : Bytes,
) -> Bool {
  let mut offset = 0
  while offset < data.length() {
    if endpoint.closed.val || endpoint.send_seq.val == 0x7fff_ffff {
      return false
    }
    let next_offset = if offset + port_forward_tcp_chunk_size > data.length() {
      data.length()
    } else {
      offset + port_forward_tcp_chunk_size
    }
    let chunk = if offset == 0 && next_offset == data.length() {
      data
    } else {
      slice_bytes(data, offset, next_offset)
    }
    let seq = endpoint.send_seq.val
    // Try the raw fast path first (bypasses msgpack encode/decode entirely).
    // Fall back to the message path for transports without raw support (UDP).
    let ok = if send_raw_port_forward_via(
        endpoint.route_protocol,
        endpoint.route_addr,
        endpoint.connection_id,
        seq,
        chunk,
      ) {
      true
    } else {
      send_port_forward_message_via(
        endpoint.peer_id,
        "port_forward_data",
        make_port_forward_data_body(
          endpoint.rule_id,
          endpoint.protocol,
          endpoint.connection_id,
          seq,
        ),
        Some(chunk),
        route_protocol=endpoint.route_protocol,
        route_addr=endpoint.route_addr,
      )
    }
    if !ok {
      return false
    }
    endpoint.send_seq.val = seq + 1
    offset = next_offset
  }
  true
}

///|
async fn send_port_forward_close_if_possible(
  peer_id : String,
  rule_id : String,
  protocol : String,
  connection_id : String,
  last_seq : Int?,
  error : String?,
  route_protocol? : String,
  route_addr? : String,
) -> Unit {
  ignore(
    send_port_forward_message_via(
      peer_id,
      "port_forward_close",
      make_port_forward_close_body(
        rule_id, protocol, connection_id, last_seq, error,
      ),
      None,
      route_protocol?,
      route_addr?,
    ),
  )
}

///|
fn remove_port_forward_udp_forward_session(session_id : String) -> Unit {
  match port_forward_registry_state.udp_forward_session_by_id.get(session_id) {
    Some(session) => {
      port_forward_registry_state.udp_forward_session_by_source.remove(
        session.rule_key + "|" + session.source_addr,
      )
      port_forward_registry_state.udp_forward_session_by_id.remove(session_id)
    }
    None => ()
  }
}

///|
fn remove_port_forward_udp_expose_session(session_id : String) -> Unit {
  match port_forward_registry_state.udp_expose_sessions.get(session_id) {
    Some(session) => {
      record_port_forward_audit_close(session.audit, "closed")
      close_port_forward_udp_client(session.client)
      port_forward_registry_state.udp_expose_sessions.remove(session_id)
    }
    None => ()
  }
}

///|
async fn run_port_forward_tcp_reader(
  endpoint : PortForwardTcpEndpoint,
  send? : async (PortForwardTcpEndpoint, Bytes) -> Bool = send_port_forward_tcp_chunks,
) -> Unit {
  let buf = FixedArray::make(port_forward_tcp_read_buffer_size, b'\x00')
  while !endpoint.closed.val {
    let n = endpoint.socket.read(buf)
    if n <= 0 {
      break
    }
    let chunk = slice_bytes(buf.unsafe_reinterpret_as_bytes(), 0, n)
    // Await each send before reading again: at most one chunk is in flight,
    // and the final close cannot overtake queued sends or sequence assignment.
    if !send(endpoint, chunk) {
      endpoint.error = Some("send_failed")
      break
    }
    endpoint.audit.bytes_out += chunk.length()
  }
}

///|
async fn accept_port_forward_tcp_connection(
  rule : PortForwardForwardRule,
  conn : @socket.Tcp,
) -> Unit {
  let connection_id = @nanoid.nanoid().unwrap_or(@env.now().to_string())
  let audit = record_port_forward_audit_open(
    rule.id,
    rule.protocol,
    get_config().id,
    rule.peer_id,
    rule.remote_host + ":" + rule.remote_port.to_string(),
  )
  let endpoint = new_port_forward_tcp_endpoint(
    conn,
    rule_id=rule.id,
    peer_id=rule.peer_id,
    protocol=rule.protocol,
    connection_id~,
    audit~,
  )
  defer close_port_forward_tcp_endpoint(endpoint)
  port_forward_registry_state.tcp_forward_connections[connection_id] = endpoint
  run_port_forward_tcp_endpoint(endpoint, () => {
    let opened = @async.with_timeout_opt(port_forward_tcp_open_timeout_ms, () => {
      let (sent, route_protocol, route_addr) = send_port_forward_message_select_route(
        rule.peer_id,
        "port_forward_open",
        make_port_forward_open_body(
          rule.id,
          rule.protocol,
          connection_id,
          target_host=rule.remote_host,
          target_port=rule.remote_port,
        ),
        None,
      )
      if !sent {
        endpoint.error = Some("peer_unavailable")
        return false
      }
      endpoint.route_protocol = route_protocol.unwrap_or("")
      endpoint.route_addr = route_addr.unwrap_or("")
      log_debug(
        "port_forward open sent rule=\{rule.id} protocol=\{rule.protocol} peer=\{rule.peer_id} connection=\{connection_id} route=\{endpoint.route_protocol}:\{endpoint.route_addr}",
      )
      wait_port_forward_tcp_open_ack(endpoint)
    })
    if opened is Some(true) {
      run_port_forward_tcp_reader(endpoint)
    } else if !endpoint.closed.val {
      endpoint.error = Some(endpoint.error.unwrap_or("open_timeout"))
      log_debug(
        "port_forward open wait failed rule=\{rule.id} protocol=\{rule.protocol} peer=\{rule.peer_id} connection=\{connection_id} error=\{endpoint.error.unwrap_or("")}",
      )
    }
  })
}

///|
fn start_port_forward_tcp_listener(
  root : @async.TaskGroup[Unit],
  rule : PortForwardForwardRule,
) -> Unit {
  root.spawn_bg(() => {
    let addr = make_port_forward_socket_addr(rule.listen_host, rule.listen_port)
    let server = @socket.TcpServer(@socket.Addr::parse(addr), reuse_addr=true) catch {
      _ => {
        log_warn("port_forward tcp listener bind failed: \{addr}")
        return
      }
    }
    let rule_key = make_port_forward_forward_rule_key(rule)
    port_forward_registry_state.tcp_forward_started[rule_key] = true
    port_forward_registry_state.tcp_forward_servers[rule_key] = server
    server.run_forever(async fn(conn, _remote_addr) {
      accept_port_forward_tcp_connection(rule, conn)
    })
  })
}

///|
async fn run_port_forward_udp_forward_listener(
  rule_key : String,
  runtime : PortForwardUdpForwardRuntime,
) -> Unit {
  let buf = FixedArray::make(65536, b'\x00')
  for ;; {
    try {
      let (n, sender) = runtime.server.recvfrom(buf)
      if n <= 0 {
        continue
      }
      let source_addr = sender.to_string()
      let lookup_key = rule_key + "|" + source_addr
      let session_id = match
        port_forward_registry_state.udp_forward_session_by_source.get(
          lookup_key,
        ) {
        Some(existing) => {
          touch_port_forward_udp_forward_session(existing)
          existing
        }
        None => {
          let next_session_id = @nanoid.nanoid().unwrap_or(
            @env.now().to_string(),
          )
          let (sent, route_protocol, route_addr) = send_port_forward_message_select_route(
            runtime.rule.peer_id,
            "port_forward_open",
            make_port_forward_open_body(
              runtime.rule.id,
              runtime.rule.protocol,
              next_session_id,
              target_host=runtime.rule.remote_host,
              target_port=runtime.rule.remote_port,
            ),
            None,
          )
          guard sent else { continue }
          port_forward_registry_state.udp_forward_session_by_source[lookup_key] = next_session_id
          port_forward_registry_state.udp_forward_session_by_id[next_session_id] = {
            rule_key,
            source_addr,
            route_protocol: route_protocol.unwrap_or(""),
            route_addr: route_addr.unwrap_or(""),
            last_seen: @env.now(),
          }
          next_session_id
        }
      }
      let chunk = slice_bytes(buf.unsafe_reinterpret_as_bytes(), 0, n)
      let route_session = port_forward_registry_state.udp_forward_session_by_id.get(
        session_id,
      )
      match route_session {
        Some(session) =>
          ignore(
            send_port_forward_message_via(
              runtime.rule.peer_id,
              "port_forward_data",
              make_port_forward_data_body(runtime.rule.id, "udp", session_id, 0),
              Some(chunk),
              route_protocol=session.route_protocol,
              route_addr=session.route_addr,
            ),
          )
        None => ()
      }
    } catch {
      _ => @async.sleep(10)
    }
  }
}

///|
fn start_port_forward_udp_listener(
  root : @async.TaskGroup[Unit],
  rule : PortForwardForwardRule,
) -> Unit {
  root.spawn_bg(() => {
    let addr = make_port_forward_socket_addr(rule.listen_host, rule.listen_port)
    let server = @socket.UdpServer(@socket.Addr::parse(addr)) catch {
      _ => {
        log_warn("port_forward udp listener bind failed: \{addr}")
        return
      }
    }
    let rule_key = make_port_forward_forward_rule_key(rule)
    let runtime = { rule, server, }
    port_forward_registry_state.udp_forward_runtimes[rule_key] = runtime
    run_port_forward_udp_forward_listener(rule_key, runtime)
  })
}

///|
fn stop_port_forward_tcp_listener(rule_key : String) -> Unit {
  match port_forward_registry_state.tcp_forward_servers.get(rule_key) {
    Some(server) => {
      server.close()
      port_forward_registry_state.tcp_forward_started.remove(rule_key)
      port_forward_registry_state.tcp_forward_servers.remove(rule_key)
    }
    None => ()
  }
}

///|
fn stop_port_forward_udp_listener(rule_key : String) -> Unit {
  match port_forward_registry_state.udp_forward_runtimes.get(rule_key) {
    Some(runtime) => {
      runtime.server.close()
      port_forward_registry_state.udp_forward_runtimes.remove(rule_key)
    }
    None => ()
  }

  let forward_sessions : Array[String] = []
  for
    session_id, session in port_forward_registry_state.udp_forward_session_by_id {
    if session.rule_key == rule_key {
      forward_sessions.push(session_id)
    }
  }
  for session_id in forward_sessions {
    remove_port_forward_udp_forward_session(session_id)
  }
}

///|
/// Returns the current set of active forward rules to be running.
///
/// Populated by [port_mapping_store] once wired; empty until then so the
/// runtime happily runs with zero mappings.
fn get_port_forward_active_forward_rules() -> Array[PortForwardForwardRule] {
  match port_mapping_store_state.active_rules {
    Some(rules) => rules
    None => []
  }
}

///|
fn refresh_port_forward_registry(root : @async.TaskGroup[Unit]) -> Unit {
  if !port_forward_registry_state.initialized {
    port_forward_registry_state.initialized = true
    root.spawn_bg(() => {
      for ;; {
        sweep_port_forward_udp_sessions()
        @async.sleep(30000)
      }
    })
  }

  let desired_tcp : Map[String, PortForwardForwardRule] = Map([])
  let desired_udp : Map[String, PortForwardForwardRule] = Map([])
  for rule in get_port_forward_active_forward_rules() {
    if !is_port_forward_rule_enabled(rule.enabled) {
      continue
    }
    let rule_key = make_port_forward_forward_rule_key(rule)
    if is_port_forward_tcp_protocol(rule.protocol) {
      desired_tcp[rule_key] = rule
    } else if port_forward_transport(rule.protocol) == "udp" {
      desired_udp[rule_key] = rule
    }
  }

  let current_tcp_keys : Array[String] = []
  for rule_key, _ in port_forward_registry_state.tcp_forward_servers {
    current_tcp_keys.push(rule_key)
  }
  for rule_key in current_tcp_keys {
    if !desired_tcp.contains(rule_key) {
      stop_port_forward_tcp_listener(rule_key)
    }
  }

  let current_udp_keys : Array[String] = []
  for rule_key, _ in port_forward_registry_state.udp_forward_runtimes {
    current_udp_keys.push(rule_key)
  }
  for rule_key in current_udp_keys {
    if !desired_udp.contains(rule_key) {
      stop_port_forward_udp_listener(rule_key)
    }
  }

  for rule_key, rule in desired_tcp {
    if !port_forward_registry_state.tcp_forward_servers.contains(rule_key) {
      start_port_forward_tcp_listener(root, rule)
    }
  }
  for rule_key, rule in desired_udp {
    if !port_forward_registry_state.udp_forward_runtimes.contains(rule_key) {
      start_port_forward_udp_listener(root, rule)
    }
  }
}

///|
fn sweep_port_forward_udp_sessions() -> Unit {
  let now = @env.now()
  let expired_forward : Array[String] = []
  let expired_expose : Array[String] = []
  for
    session_id, session in port_forward_registry_state.udp_forward_session_by_id {
    if now - session.last_seen > 60000UL {
      expired_forward.push(session_id)
    }
  }
  for session_id, session in port_forward_registry_state.udp_expose_sessions {
    if now - session.last_seen > 60000UL {
      expired_expose.push(session_id)
    }
  }
  for session_id in expired_forward {
    remove_port_forward_udp_forward_session(session_id)
  }
  for session_id in expired_expose {
    remove_port_forward_udp_expose_session(session_id)
  }
}

///|
fn init_port_forward_registry(root : @async.TaskGroup[Unit]) -> Unit {
  refresh_port_forward_registry(root)
}
