///|
async fn send_port_forward_message(
  peer_id : String,
  kind : String,
  body : @msgpack.Value,
  attachment : Bytes?,
) -> Unit {
  ignore(send_port_forward_message_via(peer_id, kind, body, attachment))
}

///|
async fn send_port_forward_message_via(
  peer_id : String,
  kind : String,
  body : @msgpack.Value,
  attachment : Bytes?,
  route_protocol? : String,
  route_addr? : String,
) -> Bool {
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
  if route_protocol is Some(protocol) &&
    route_addr is Some(addr) &&
    protocol != "" &&
    addr != "" {
    let ok = send_message_via_route(protocol, addr, msg)
    log_debug(
      "port_forward send kind=\{kind} peer=\{peer_id} route=\{protocol}://\{addr} ok=\{ok}",
    )
    return ok
  }
  let ok = send_message_now(peer_id, msg)
  log_debug(
    "port_forward send kind=\{kind} peer=\{peer_id} route=auto ok=\{ok}",
  )
  ok
}

///|
async fn send_port_forward_message_select_route(
  peer_id : String,
  kind : String,
  body : @msgpack.Value,
  attachment : Bytes?,
) -> (Bool, String?, String?) {
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
  send_message_now_with_route(peer_id, msg)
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
  let err = error.unwrap_or("")
  log_debug(
    "port_forward open_ack connection=\{connection_id} ok=\{ok} error=\{err}",
  )
  match get_port_forward_tcp_forward_connection(connection_id) {
    Some(endpoint) => {
      endpoint.opened = ok
      endpoint.failed = !ok
      endpoint.error = error
      port_forward_registry_state.tcp_forward_connections[connection_id] = endpoint
      endpoint.cond.signal()
      if !ok {
        match remove_port_forward_tcp_forward_connection(connection_id) {
          Some(value) => {
            record_port_forward_audit_close(
              value.audit,
              error.unwrap_or("open_failed"),
            )
            close_port_forward_tcp_endpoint(value)
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
    log_debug(
      "port_forward open invalid requester=\{msg.source_id} rule=\{rule_id} protocol=\{protocol}",
    )
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
  log_debug(
    "port_forward open request requester=\{msg.source_id} rule=\{rule_id} protocol=\{protocol} connection=\{connection_id}",
  )
  match find_port_forward_expose_rule(rule_id, protocol) {
    Some(rule) =>
      if is_port_forward_tcp_protocol(protocol) {
        ctx.root.spawn_bg(async fn() {
          log_debug(
            "port_forward open begin connect requester=\{msg.source_id} rule=\{rule_id} target=\{rule.target_host}:\{rule.target_port}",
          )
          let conn = @socket.Tcp::connect_to_host(
            rule.target_host,
            port=rule.target_port,
          ) catch {
            _ => {
              log_debug(
                "port_forward open tcp connect failed requester=\{msg.source_id} rule=\{rule_id} target=\{rule.target_host}:\{rule.target_port}",
              )
              ignore(
                send_port_forward_message_via(
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
                  route_protocol=ctx.transport.protocol(),
                  route_addr=ctx.sender_addr,
                ),
              )
              return
            }
          }
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
            rule_id,
            peer_id: msg.source_id,
            protocol: "tcp",
            connection_id,
            route_protocol: ctx.transport.protocol(),
            route_addr: ctx.sender_addr,
            opened: true,
            failed: false,
            error: None,
            audit: record_port_forward_audit_open(
              rule_id,
              protocol,
              msg.source_id,
              get_config().id,
              rule.target_host + ":" + rule.target_port.to_string(),
            ),
          }
          port_forward_registry_state.tcp_expose_connections[connection_id] = endpoint
          log_debug(
            "port_forward open tcp established requester=\{msg.source_id} rule=\{rule_id} target=\{rule.target_host}:\{rule.target_port}",
          )
          ignore(
            send_port_forward_message_via(
              msg.source_id,
              "port_forward_open_ack",
              make_port_forward_open_ack_body(
                rule_id,
                protocol,
                connection_id,
                true,
                None,
              ),
              None,
              route_protocol=ctx.transport.protocol(),
              route_addr=ctx.sender_addr,
            ),
          )
          run_port_forward_expose_tcp_reader(endpoint)
          match remove_port_forward_tcp_expose_connection(connection_id) {
            Some(value) => {
              record_port_forward_audit_close(value.audit, "closed")
              close_port_forward_tcp_endpoint(value)
            }
            None => ()
          }
        })
      } else if protocol == "udp" {
        ctx.root.spawn_bg(async fn() {
          let server_addr = @socket.Addr::resolve(
            rule.target_host,
            port=rule.target_port,
          ) catch {
            _ => {
              log_debug(
                "port_forward open udp resolve failed requester=\{msg.source_id} rule=\{rule_id} target=\{rule.target_host}:\{rule.target_port}",
              )
              ignore(
                send_port_forward_message_via(
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
                  route_protocol=ctx.transport.protocol(),
                  route_addr=ctx.sender_addr,
                ),
              )
              return
            }
          }
          let client = @socket.UdpClient::new(server_addr) catch {
            _ => {
              log_debug(
                "port_forward open udp client failed requester=\{msg.source_id} rule=\{rule_id} target=\{rule.target_host}:\{rule.target_port}",
              )
              ignore(
                send_port_forward_message_via(
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
                  route_protocol=ctx.transport.protocol(),
                  route_addr=ctx.sender_addr,
                ),
              )
              return
            }
          }
          let session = {
            peer_id: msg.source_id,
            route_protocol: ctx.transport.protocol(),
            route_addr: ctx.sender_addr,
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
          log_debug(
            "port_forward open udp established requester=\{msg.source_id} rule=\{rule_id} target=\{rule.target_host}:\{rule.target_port}",
          )
          ignore(
            send_port_forward_message_via(
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
              route_protocol=ctx.transport.protocol(),
              route_addr=ctx.sender_addr,
            ),
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
              ignore(
                send_port_forward_message_via(
                  session.peer_id,
                  "port_forward_data",
                  make_port_forward_data_body(rule_id, "udp", connection_id, 0),
                  Some(chunk),
                  route_protocol=session.route_protocol,
                  route_addr=session.route_addr,
                ),
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
            None,
            route_protocol=session.route_protocol,
            route_addr=session.route_addr,
          )
          remove_port_forward_udp_expose_session(connection_id)
        })
      } else {
        log_debug(
          "port_forward open unsupported protocol requester=\{msg.source_id} rule=\{rule_id} protocol=\{protocol}",
        )
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
    None => {
      log_debug(
        "port_forward open rule not found requester=\{msg.source_id} rule=\{rule_id} protocol=\{protocol}",
      )
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
  let seq = port_forward_int_field(msg.body, "seq").unwrap_or(0)
  let data = msg.attachment.unwrap_or(
    match msg.body {
      Binary(b) => b
      _ => b""
    },
  )
  if connection_id == "" || data.length() == 0 {
    return
  }
  if is_port_forward_tcp_protocol(protocol) {
    match get_port_forward_tcp_forward_connection(connection_id) {
      Some(endpoint) =>
        if !queue_port_forward_tcp_recv_chunk(endpoint, seq, data) {
          match remove_port_forward_tcp_forward_connection(connection_id) {
            Some(value) => {
              record_port_forward_audit_close(value.audit, "write_failed")
              close_port_forward_tcp_endpoint(value)
            }
            None => ()
          }
        } else {
          ensure_port_forward_tcp_writer(ctx.root, endpoint)
        }
      None =>
        match get_port_forward_tcp_expose_connection(connection_id) {
          Some(endpoint) =>
            if !queue_port_forward_tcp_recv_chunk(endpoint, seq, data) {
              match remove_port_forward_tcp_expose_connection(connection_id) {
                Some(value) => {
                  record_port_forward_audit_close(value.audit, "write_failed")
                  close_port_forward_tcp_endpoint(value)
                }
                None => ()
              }
            } else {
              ensure_port_forward_tcp_writer(ctx.root, endpoint)
            }
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
  let last_seq = port_forward_int_field(msg.body, "last_seq")
  if connection_id == "" {
    return
  }
  match get_port_forward_tcp_forward_connection(connection_id) {
    Some(endpoint) => {
      endpoint.error = Some("closed")
      endpoint.remote_close_seq.val = last_seq
      if should_finalize_port_forward_tcp_remote_close(endpoint) {
        finalize_port_forward_tcp_remote_close(connection_id)
      }
      return
    }
    None => ()
  }
  match get_port_forward_tcp_expose_connection(connection_id) {
    Some(endpoint) => {
      endpoint.error = Some("closed")
      endpoint.remote_close_seq.val = last_seq
      if should_finalize_port_forward_tcp_remote_close(endpoint) {
        finalize_port_forward_tcp_remote_close(connection_id)
      }
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
