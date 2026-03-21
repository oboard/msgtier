///|
fn close_port_forward_tcp_socket(socket : @socket.Tcp) -> Unit {
  socket.close()
}

///|
fn close_port_forward_udp_client(client : @socket.UdpClient) -> Unit {
  client.close()
}

///|
async fn write_port_forward_tcp(
  endpoint : PortForwardTcpEndpoint,
  data : Bytes,
) -> Bool {
  while endpoint.sending.val {
    @async.sleep(1)
  }
  endpoint.sending.val = true
  try {
    endpoint.socket.write(data)
    endpoint.sending.val = false
    endpoint.audit.bytes_in = endpoint.audit.bytes_in + data.length()
    true
  } catch {
    _ => {
      endpoint.sending.val = false
      false
    }
  }
}

///|
async fn send_port_forward_close_if_possible(
  peer_id : String,
  rule_id : String,
  protocol : String,
  connection_id : String,
  error : String?,
) -> Unit {
  send_port_forward_message(
    peer_id,
    "port_forward_close",
    make_port_forward_close_body(rule_id, protocol, connection_id, error),
    None,
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
  remote_peer_id : String,
) -> Unit {
  try {
    for ;; {
      match endpoint.socket.read_some() {
        Some(chunk) =>
          if chunk.length() == 0 {
            break
          } else {
            endpoint.audit.bytes_out = endpoint.audit.bytes_out + chunk.length()
            send_port_forward_message(
              remote_peer_id,
              "port_forward_data",
              make_port_forward_data_body(
                endpoint.rule_id,
                endpoint.protocol,
                endpoint.connection_id,
              ),
              Some(chunk),
            )
          }
        None => break
      }
    }
  } catch {
    _ => ()
  }
  send_port_forward_close_if_possible(
    remote_peer_id,
    endpoint.rule_id,
    endpoint.protocol,
    endpoint.connection_id,
    None,
  )
}

///|
async fn accept_port_forward_tcp_connection(
  root : @async.TaskGroup[Unit],
  rule : PortForwardForwardRule,
  conn : @socket.Tcp,
) -> Unit {
  let connection_id = @nanoid.nanoid().unwrap_or(@env.now().to_string())
  let audit = record_port_forward_audit_open(
    rule.id,
    "tcp",
    get_config().id,
    rule.peer_id,
    rule.listen_host + ":" + rule.listen_port.to_string(),
  )
  let endpoint = {
    socket: conn,
    sending: Ref::new(false),
    cond: @cond_var.Cond::new(),
    rule_id: rule.id,
    peer_id: rule.peer_id,
    protocol: "tcp",
    connection_id,
    opened: false,
    failed: false,
    error: None,
    audit,
  }
  port_forward_registry_state.tcp_forward_connections[connection_id] = endpoint
  send_port_forward_message(
    rule.peer_id,
    "port_forward_open",
    make_port_forward_open_body(rule.id, "tcp", connection_id),
    None,
  )
  let opened = @async.with_timeout_opt(5000, async fn() {
    for ;; {
      if endpoint.opened || endpoint.failed {
        break endpoint.opened
      }
      endpoint.cond.wait()
    }
  })
  match opened {
    Some(true) =>
      root.spawn_bg(async fn() {
        run_port_forward_tcp_reader(endpoint, rule.peer_id)
      })
    _ => {
      let closed = remove_port_forward_tcp_forward_connection(connection_id)
      match closed {
        Some(value) => {
          record_port_forward_audit_close(
            value.audit,
            value.error.unwrap_or("open_timeout"),
          )
          close_port_forward_tcp_socket(value.socket)
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
  root.spawn_bg(async fn() {
    server.run_forever(async fn(conn, _remote_addr) {
      accept_port_forward_tcp_connection(root, rule, conn)
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
          port_forward_registry_state.udp_forward_session_by_source[lookup_key] = next_session_id
          port_forward_registry_state.udp_forward_session_by_id[next_session_id] = {
            session_id: next_session_id,
            rule_key,
            rule_id: runtime.rule.id,
            peer_id: runtime.rule.peer_id,
            source_addr,
            last_seen: @env.now(),
          }
          send_port_forward_message(
            runtime.rule.peer_id,
            "port_forward_open",
            make_port_forward_open_body(runtime.rule.id, "udp", next_session_id),
            None,
          )
          next_session_id
        }
      }
      let chunk = slice_bytes(buf.unsafe_reinterpret_as_bytes(), 0, n)
      send_port_forward_message(
        runtime.rule.peer_id,
        "port_forward_data",
        make_port_forward_data_body(runtime.rule.id, "udp", session_id),
        Some(chunk),
      )
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
  port_forward_registry_state.udp_forward_started[rule_key] = true
  let runtime = { rule, server }
  port_forward_registry_state.udp_forward_runtimes[rule_key] = runtime
  root.spawn_bg(async fn() {
    run_port_forward_udp_forward_listener(rule_key, runtime)
  })
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
  if port_forward_registry_state.initialized {
    return
  }
  port_forward_registry_state.initialized = true
  for rule in get_port_forward_forward_rules() {
    if !is_port_forward_rule_enabled(rule.enabled) {
      continue
    }
    let rule_key = make_port_forward_forward_rule_key(rule)
    if rule.protocol == "tcp" &&
      !port_forward_registry_state.tcp_forward_started.contains(rule_key) {
      start_port_forward_tcp_listener(root, rule)
    } else if rule.protocol == "udp" &&
      !port_forward_registry_state.udp_forward_started.contains(rule_key) {
      start_port_forward_udp_listener(root, rule)
    }
  }
  root.spawn_bg(async fn() {
    for ;; {
      sweep_port_forward_udp_sessions()
      @async.sleep(30000)
    }
  })
}
