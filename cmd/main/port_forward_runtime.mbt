///|
let port_forward_tcp_chunk_size : Int = 256 * 1024

///|
fn close_port_forward_tcp_socket(socket : @socket.Tcp) -> Unit {
  socket.close()
}

///|
fn close_port_forward_udp_client(client : @socket.UdpClient) -> Unit {
  client.close()
}

///|
async fn write_port_forward_tcp_now(
  endpoint : PortForwardTcpEndpoint,
  data : Bytes,
) -> Bool {
  try {
    endpoint.socket.write(data)
    endpoint.audit.bytes_in = endpoint.audit.bytes_in + data.length()
    true
  } catch {
    _ => false
  }
}

///|
fn next_port_forward_tcp_seq(endpoint : PortForwardTcpEndpoint) -> Int {
  let seq = endpoint.send_seq.val
  endpoint.send_seq.val = seq + 1
  seq
}

///|
fn queue_port_forward_tcp_recv_chunk(
  endpoint : PortForwardTcpEndpoint,
  seq : Int,
  data : Bytes,
) -> Bool {
  guard !endpoint.closed.val else { return false }
  if seq < endpoint.recv_next_seq.val {
    return true
  }
  endpoint.recv_buffer.val[seq] = data
  let mut enqueued = false
  for ;; {
    let next_seq = endpoint.recv_next_seq.val
    match endpoint.recv_buffer.val.get(next_seq) {
      Some(chunk) => {
        endpoint.recv_buffer.val.remove(next_seq)
        endpoint.pending_writes.val.push(chunk)
        endpoint.recv_next_seq.val = next_seq + 1
        enqueued = true
      }
      None => break
    }
  }
  if enqueued {
    endpoint.cond.signal()
  }
  true
}

///|
fn should_finalize_port_forward_tcp_remote_close(
  endpoint : PortForwardTcpEndpoint,
) -> Bool {
  match endpoint.remote_close_seq.val {
    Some(last_seq) =>
      endpoint.recv_next_seq.val > last_seq &&
      endpoint.pending_writes.val.is_empty() &&
      !endpoint.draining.val
    None => false
  }
}

///|
fn finalize_port_forward_tcp_remote_close(connection_id : String) -> Unit {
  match remove_port_forward_tcp_forward_connection(connection_id) {
    Some(endpoint) => {
      endpoint.closed.val = true
      if endpoint.audit.ended_at is None {
        record_port_forward_audit_close(
          endpoint.audit,
          endpoint.error.unwrap_or("closed"),
        )
      }
      close_port_forward_tcp_socket(endpoint.socket)
      return
    }
    None => ()
  }
  match remove_port_forward_tcp_expose_connection(connection_id) {
    Some(endpoint) => {
      endpoint.closed.val = true
      if endpoint.audit.ended_at is None {
        record_port_forward_audit_close(
          endpoint.audit,
          endpoint.error.unwrap_or("closed"),
        )
      }
      close_port_forward_tcp_socket(endpoint.socket)
      return
    }
    None => ()
  }
}

///|
fn stop_port_forward_tcp_endpoint(endpoint : PortForwardTcpEndpoint) -> Unit {
  endpoint.closed.val = true
  endpoint.cond.signal()
}

///|
fn close_port_forward_tcp_endpoint(endpoint : PortForwardTcpEndpoint) -> Unit {
  stop_port_forward_tcp_endpoint(endpoint)
  close_port_forward_tcp_socket(endpoint.socket)
}

///|
async fn run_port_forward_tcp_writer(endpoint : PortForwardTcpEndpoint) -> Bool {
  let mut ok = true
  for ;; {
    match endpoint.pending_writes.val {
      [data, .. rest] => {
        endpoint.pending_writes.val = rest.to_array()
        if !write_port_forward_tcp_now(endpoint, data) {
          ok = false
          break
        }
      }
      _ => if endpoint.closed.val { break } else { endpoint.cond.wait() }
    }
  }
  endpoint.draining.val = false
  if should_finalize_port_forward_tcp_remote_close(endpoint) {
    finalize_port_forward_tcp_remote_close(endpoint.connection_id)
    return ok
  }
  if endpoint.closed.val {
    if endpoint.audit.ended_at is None {
      record_port_forward_audit_close(
        endpoint.audit,
        endpoint.error.unwrap_or("closed"),
      )
    }
    close_port_forward_tcp_socket(endpoint.socket)
  }
  ok
}

///|
fn ensure_port_forward_tcp_writer(
  root : @async.TaskGroup[Unit],
  endpoint : PortForwardTcpEndpoint,
) -> Unit {
  if endpoint.draining.val {
    return
  }
  endpoint.draining.val = true
  root.spawn_bg(async fn() {
    if !run_port_forward_tcp_writer(endpoint) {
      stop_port_forward_tcp_endpoint(endpoint)
    }
  })
}

///|
async fn send_port_forward_tcp_chunks(
  endpoint : PortForwardTcpEndpoint,
  data : Bytes,
) -> Bool {
  let mut offset = 0
  while offset < data.length() {
    let next_offset = if offset + port_forward_tcp_chunk_size > data.length() {
      data.length()
    } else {
      offset + port_forward_tcp_chunk_size
    }
    let chunk = slice_bytes(data, offset, next_offset)
    let seq = next_port_forward_tcp_seq(endpoint)
    let ok = send_port_forward_message_via(
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
    if !ok {
      return false
    }
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
async fn run_port_forward_tcp_reader(endpoint : PortForwardTcpEndpoint) -> Unit {
  let buf = FixedArray::make(65536, b'\x00')
  try {
    for ;; {
      let n = endpoint.socket.read(buf)
      if n <= 0 {
        break
      }
      let chunk = slice_bytes(buf.unsafe_reinterpret_as_bytes(), 0, n)
      endpoint.audit.bytes_out = endpoint.audit.bytes_out + chunk.length()
      if !send_port_forward_tcp_chunks(endpoint, chunk) {
        break
      }
    }
  } catch {
    _ => ()
  }
  send_port_forward_close_if_possible(
    endpoint.peer_id,
    endpoint.rule_id,
    endpoint.protocol,
    endpoint.connection_id,
    if endpoint.send_seq.val > 0 {
      Some(endpoint.send_seq.val - 1)
    } else {
      None
    },
    None,
    route_protocol=endpoint.route_protocol,
    route_addr=endpoint.route_addr,
  )
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
    rule.listen_host + ":" + rule.listen_port.to_string(),
  )
  let endpoint = {
    socket: conn,
    send_seq: Ref::new(0),
    recv_next_seq: Ref::new(0),
    remote_close_seq: Ref::new(None),
    recv_buffer: Ref::new({}),
    pending_writes: Ref::new([]),
    draining: Ref::new(false),
    closed: Ref::new(false),
    cond: @cond_var.Cond::new(),
    rule_id: rule.id,
    peer_id: rule.peer_id,
    protocol: rule.protocol,
    connection_id,
    route_protocol: "",
    route_addr: "",
    opened: false,
    failed: false,
    error: None,
    audit,
  }
  port_forward_registry_state.tcp_forward_connections[connection_id] = endpoint
  let (sent, route_protocol, route_addr) = send_port_forward_message_select_route(
    rule.peer_id,
    "port_forward_open",
    make_port_forward_open_body(rule.id, rule.protocol, connection_id),
    None,
  )
  if !sent {
    log_debug(
      "port_forward open send failed rule=\{rule.id} protocol=\{rule.protocol} peer=\{rule.peer_id} connection=\{connection_id}",
    )
    let closed = remove_port_forward_tcp_forward_connection(connection_id)
    match closed {
      Some(value) => {
        record_port_forward_audit_close(value.audit, "peer_unavailable")
        close_port_forward_tcp_endpoint(value)
      }
      None => ()
    }
    return
  }
  endpoint.route_protocol = route_protocol.unwrap_or("")
  endpoint.route_addr = route_addr.unwrap_or("")
  log_debug(
    "port_forward open sent rule=\{rule.id} protocol=\{rule.protocol} peer=\{rule.peer_id} connection=\{connection_id} route=\{endpoint.route_protocol}:\{endpoint.route_addr}",
  )
  port_forward_registry_state.tcp_forward_connections[connection_id] = endpoint
  let opened = @async.with_timeout_opt(5000, async fn() {
    for ;; {
      match get_port_forward_tcp_forward_connection(connection_id) {
        Some(current) =>
          if current.opened || current.failed {
            break current.opened
          } else {
            current.cond.wait()
          }
        None => break false
      }
    }
  })
  match opened {
    Some(true) => {
      run_port_forward_tcp_reader(endpoint)
      match remove_port_forward_tcp_forward_connection(connection_id) {
        Some(value) => {
          record_port_forward_audit_close(value.audit, "closed")
          close_port_forward_tcp_endpoint(value)
        }
        None => ()
      }
    }
    _ => {
      let open_error = endpoint.error.unwrap_or("open_timeout")
      log_debug(
        "port_forward open wait failed rule=\{rule.id} protocol=tcp peer=\{rule.peer_id} connection=\{connection_id} error=\{open_error}",
      )
      let closed = remove_port_forward_tcp_forward_connection(connection_id)
      match closed {
        Some(value) => {
          record_port_forward_audit_close(
            value.audit,
            value.error.unwrap_or("open_timeout"),
          )
          close_port_forward_tcp_endpoint(value)
        }
        None => ()
      }
    }
  }
}

///|
fn start_port_forward_tcp_listener(
  root : @async.TaskGroup[Unit],
  rule : PortForwardForwardRule,
) -> Unit {
  let addr = make_port_forward_socket_addr(rule.listen_host, rule.listen_port)
  let server = @socket.TcpServer::new(
    @socket.Addr::parse(addr),
    reuse_addr=true,
  ) catch {
    _ => {
      log_warn("port_forward tcp listener bind failed: \{addr}")
      return
    }
  }
  let rule_key = make_port_forward_forward_rule_key(rule)
  port_forward_registry_state.tcp_forward_started[rule_key] = true
  port_forward_registry_state.tcp_forward_servers[rule_key] = server
  root.spawn_bg(async fn() {
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
            make_port_forward_open_body(runtime.rule.id, "udp", next_session_id),
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
  let addr = make_port_forward_socket_addr(rule.listen_host, rule.listen_port)
  let server = @socket.UdpServer::new(@socket.Addr::parse(addr)) catch {
    _ => {
      log_warn("port_forward udp listener bind failed: \{addr}")
      return
    }
  }
  let rule_key = make_port_forward_forward_rule_key(rule)
  let runtime = { rule, server }
  port_forward_registry_state.udp_forward_runtimes[rule_key] = runtime
  root.spawn_bg(async fn() {
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
fn refresh_port_forward_registry(root : @async.TaskGroup[Unit]) -> Unit {
  if !port_forward_registry_state.initialized {
    port_forward_registry_state.initialized = true
    root.spawn_bg(async fn() {
      for ;; {
        sweep_port_forward_udp_sessions()
        @async.sleep(30000)
      }
    })
  }

  let desired_tcp : Map[String, PortForwardForwardRule] = {}
  let desired_udp : Map[String, PortForwardForwardRule] = {}
  for rule in get_port_forward_forward_rules() {
    if !is_port_forward_rule_enabled(rule.enabled) {
      continue
    }
    let rule_key = make_port_forward_forward_rule_key(rule)
    if is_port_forward_tcp_protocol(rule.protocol) {
      desired_tcp[rule_key] = rule
    } else if rule.protocol == "udp" {
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
