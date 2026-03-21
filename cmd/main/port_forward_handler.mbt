///|
async fn send_port_forward_message(
  peer_id : String,
  kind : String,
  body : @msgpack.Value,
  attachment : Bytes?,
) -> Unit {
  let config = get_config()
  let msg = Message::new(
    kind~,
    source_id=config.id,
    relay=1,
    version=app_state.version,
    target_id=peer_id,
    body~,
    attachment?,
    encrypted=config.is_encrypt(),
    timeout_ms=60000,
  )
  if !send_message_now(peer_id, msg) {
    add_pending_message(msg)
  }
}

///|
fn port_forward_message_plugin() -> MessagePlugin {
  { register: register_port_forward_handlers }
}

///|
fn register_port_forward_handlers(dispatcher : MessageDispatcher) -> Unit {
  dispatcher.register("port_forward_open", handle_port_forward_open_message)
  dispatcher.register(
    "port_forward_open_ack", handle_port_forward_open_ack_message,
  )
  dispatcher.register("port_forward_data", handle_port_forward_data_message)
  dispatcher.register("port_forward_close", handle_port_forward_close_message)
  dispatcher.register("port_forward_error", handle_port_forward_error_message)
}

///|
fn mark_port_forward_open_ack(
  connection_id : String,
  ok : Bool,
  error : String?,
) -> Unit {
  match get_port_forward_tcp_forward_connection(connection_id) {
    Some(endpoint) => {
      endpoint.opened = ok
      endpoint.failed = !ok
      endpoint.error = error
      endpoint.cond.signal()
      if !ok {
        match remove_port_forward_tcp_forward_connection(connection_id) {
          Some(value) => {
            record_port_forward_audit_close(
              value.audit,
              error.unwrap_or("open_failed"),
            )
            close_port_forward_tcp_socket(value.socket)
          }
          None => ()
        }
      }
    }
    None => ()
  }
}

///|
async fn run_port_forward_expose_tcp_reader(
  endpoint : PortForwardTcpEndpoint,
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
              endpoint.peer_id,
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
    endpoint.peer_id,
    endpoint.rule_id,
    endpoint.protocol,
    endpoint.connection_id,
    None,
  )
  match remove_port_forward_tcp_expose_connection(endpoint.connection_id) {
    Some(value) => {
      record_port_forward_audit_close(value.audit, "closed")
      close_port_forward_tcp_socket(value.socket)
    }
    None => ()
  }
}

///|
fn handle_port_forward_open_message(ctx : MessageContext) -> Unit {
  let msg = ctx.msg
  if check_and_mark_processed(msg.id, msg.timestamp) {
    return
  }
  let rule_id = port_forward_string_field(msg.body, "rule_id").unwrap_or("")
  let protocol = port_forward_string_field(msg.body, "protocol").unwrap_or("")
  let connection_id = port_forward_string_field(msg.body, "connection_id").unwrap_or(
    "",
  )
  if rule_id == "" || connection_id == "" {
    ctx.root.spawn_bg(async fn() {
      send_port_forward_message(
        msg.source_id,
        "port_forward_open_ack",
        make_port_forward_open_ack_body(
          rule_id,
          protocol,
          connection_id,
          false,
          Some("invalid_open"),
        ),
        None,
      )
    })
    return
  }
  match find_port_forward_expose_rule(rule_id, protocol, msg.source_id) {
    Some(rule) =>
      if protocol == "tcp" {
        ctx.root.spawn_bg(async fn() {
          let conn = @socket.Tcp::connect_to_host(
            rule.target_host,
            port=rule.target_port,
          ) catch {
            _ => {
              send_port_forward_message(
                msg.source_id,
                "port_forward_open_ack",
                make_port_forward_open_ack_body(
                  rule_id,
                  protocol,
                  connection_id,
                  false,
                  Some("target_connect_failed"),
                ),
                None,
              )
              return
            }
          }
          let endpoint = {
            socket: conn,
            sending: Ref::new(false),
            cond: @cond_var.Cond::new(),
            rule_id,
            peer_id: msg.source_id,
            protocol: "tcp",
            connection_id,
            opened: true,
            failed: false,
            error: None,
            audit: record_port_forward_audit_open(
              rule_id,
              "tcp",
              msg.source_id,
              get_config().id,
              rule.target_host + ":" + rule.target_port.to_string(),
            ),
          }
          port_forward_registry_state.tcp_expose_connections[connection_id] = endpoint
          send_port_forward_message(
            msg.source_id,
            "port_forward_open_ack",
            make_port_forward_open_ack_body(
              rule_id,
              "tcp",
              connection_id,
              true,
              None,
            ),
            None,
          )
          run_port_forward_expose_tcp_reader(endpoint)
        })
      } else if protocol == "udp" {
        ctx.root.spawn_bg(async fn() {
          let server_addr = @socket.Addr::resolve(
            rule.target_host,
            port=rule.target_port,
          ) catch {
            _ => {
              send_port_forward_message(
                msg.source_id,
                "port_forward_open_ack",
                make_port_forward_open_ack_body(
                  rule_id,
                  protocol,
                  connection_id,
                  false,
                  Some("target_resolve_failed"),
                ),
                None,
              )
              return
            }
          }
          let client = @socket.UdpClient::new(server_addr) catch {
            _ => {
              send_port_forward_message(
                msg.source_id,
                "port_forward_open_ack",
                make_port_forward_open_ack_body(
                  rule_id,
                  protocol,
                  connection_id,
                  false,
                  Some("target_connect_failed"),
                ),
                None,
              )
              return
            }
          }
          let session = {
            session_id: connection_id,
            rule_id,
            peer_id: msg.source_id,
            client,
            last_seen: @env.now(),
            audit: record_port_forward_audit_open(
              rule_id,
              "udp",
              msg.source_id,
              get_config().id,
              rule.target_host + ":" + rule.target_port.to_string(),
            ),
          }
          port_forward_registry_state.udp_expose_sessions[connection_id] = session
          send_port_forward_message(
            msg.source_id,
            "port_forward_open_ack",
            make_port_forward_open_ack_body(
              rule_id,
              "udp",
              connection_id,
              true,
              None,
            ),
            None,
          )
          let buf = FixedArray::make(65536, b'\x00')
          try {
            for ;; {
              let n = session.client.recv(buf)
              if n <= 0 {
                break
              }
              touch_port_forward_udp_expose_session(connection_id)
              let chunk = slice_bytes(buf.unsafe_reinterpret_as_bytes(), 0, n)
              session.audit.bytes_out = session.audit.bytes_out + chunk.length()
              send_port_forward_message(
                session.peer_id,
                "port_forward_data",
                make_port_forward_data_body(rule_id, "udp", connection_id),
                Some(chunk),
              )
            }
          } catch {
            _ => ()
          }
          send_port_forward_close_if_possible(
            session.peer_id,
            rule_id,
            "udp",
            connection_id,
            None,
          )
          remove_port_forward_udp_expose_session(connection_id)
        })
      } else {
        ctx.root.spawn_bg(async fn() {
          send_port_forward_message(
            msg.source_id,
            "port_forward_open_ack",
            make_port_forward_open_ack_body(
              rule_id,
              protocol,
              connection_id,
              false,
              Some("protocol_mismatch"),
            ),
            None,
          )
        })
      }
    None =>
      ctx.root.spawn_bg(async fn() {
        send_port_forward_message(
          msg.source_id,
          "port_forward_open_ack",
          make_port_forward_open_ack_body(
            rule_id,
            protocol,
            connection_id,
            false,
            Some("rejected"),
          ),
          None,
        )
      })
  }
}

///|
fn handle_port_forward_open_ack_message(ctx : MessageContext) -> Unit {
  let msg = ctx.msg
  let connection_id = port_forward_string_field(msg.body, "connection_id").unwrap_or(
    "",
  )
  let ok = port_forward_bool_field(msg.body, "ok").unwrap_or(false)
  let error = port_forward_string_field(msg.body, "error")
  if connection_id != "" {
    mark_port_forward_open_ack(connection_id, ok, error)
  }
}

///|
fn handle_port_forward_data_message(ctx : MessageContext) -> Unit {
  let msg = ctx.msg
  let protocol = port_forward_string_field(msg.body, "protocol").unwrap_or("")
  let connection_id = port_forward_string_field(msg.body, "connection_id").unwrap_or(
    "",
  )
  let data = msg.attachment.unwrap_or(
    match msg.body {
      Binary(b) => b
      _ => b""
    },
  )
  if connection_id == "" || data.length() == 0 {
    return
  }
  if protocol == "tcp" {
    match get_port_forward_tcp_forward_connection(connection_id) {
      Some(endpoint) =>
        ctx.root.spawn_bg(async fn() {
          if !write_port_forward_tcp(endpoint, data) {
            match remove_port_forward_tcp_forward_connection(connection_id) {
              Some(value) => {
                record_port_forward_audit_close(value.audit, "write_failed")
                close_port_forward_tcp_socket(value.socket)
              }
              None => ()
            }
          }
        })
      None =>
        match get_port_forward_tcp_expose_connection(connection_id) {
          Some(endpoint) =>
            ctx.root.spawn_bg(async fn() {
              if !write_port_forward_tcp(endpoint, data) {
                match remove_port_forward_tcp_expose_connection(connection_id) {
                  Some(value) => {
                    record_port_forward_audit_close(value.audit, "write_failed")
                    close_port_forward_tcp_socket(value.socket)
                  }
                  None => ()
                }
              }
            })
          None => ()
        }
    }
  } else if protocol == "udp" {
    match
      port_forward_registry_state.udp_forward_session_by_id.get(connection_id) {
      Some(session) =>
        match
          port_forward_registry_state.udp_forward_runtimes.get(session.rule_key) {
          Some(runtime) =>
            ctx.root.spawn_bg(async fn() {
              touch_port_forward_udp_forward_session(connection_id)
              let addr_opt : @socket.Addr? = Some(
                @socket.Addr::parse(session.source_addr),
              ) catch {
                _ => None
              }
              match addr_opt {
                Some(addr) =>
                  runtime.server.sendto(data, addr) catch {
                    _ => ()
                  }
                None => ()
              }
            })
          None => ()
        }
      None =>
        match
          port_forward_registry_state.udp_expose_sessions.get(connection_id) {
          Some(session) =>
            ctx.root.spawn_bg(async fn() {
              touch_port_forward_udp_expose_session(connection_id)
              session.audit.bytes_in = session.audit.bytes_in + data.length()
              session.client.send(data) catch {
                _ => ()
              }
            })
          None => ()
        }
    }
  }
}

///|
fn handle_port_forward_close_message(ctx : MessageContext) -> Unit {
  let msg = ctx.msg
  let connection_id = port_forward_string_field(msg.body, "connection_id").unwrap_or(
    "",
  )
  if connection_id == "" {
    return
  }
  match remove_port_forward_tcp_forward_connection(connection_id) {
    Some(endpoint) => {
      record_port_forward_audit_close(endpoint.audit, "closed")
      close_port_forward_tcp_socket(endpoint.socket)
      return
    }
    None => ()
  }
  match remove_port_forward_tcp_expose_connection(connection_id) {
    Some(endpoint) => {
      record_port_forward_audit_close(endpoint.audit, "closed")
      close_port_forward_tcp_socket(endpoint.socket)
      return
    }
    None => ()
  }
  if port_forward_registry_state.udp_forward_session_by_id.contains(
      connection_id,
    ) {
    remove_port_forward_udp_forward_session(connection_id)
    return
  }
  remove_port_forward_udp_expose_session(connection_id)
}

///|
fn handle_port_forward_error_message(ctx : MessageContext) -> Unit {
  handle_port_forward_close_message(ctx)
}
