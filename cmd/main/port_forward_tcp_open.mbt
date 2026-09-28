///|
async fn wait_port_forward_tcp_open_ack(
  endpoint : PortForwardTcpEndpoint,
) -> Bool noraise {
  while !endpoint.closed.val && !endpoint.opened && !endpoint.failed {
    endpoint.cond.wait()
  }
  endpoint.opened && !endpoint.closed.val
}

///|
fn start_port_forward_expose_tcp_connection(
  ctx : MessageContext,
  rule_id : String,
  protocol : String,
  connection_id : String,
  target_host : String,
  target_port : Int,
) -> Unit {
  let state = port_forward_registry_state
  if state.tcp_expose_pending_opens.contains(connection_id) ||
    state.tcp_expose_connections.contains(connection_id) ||
    state.tcp_forward_connections.contains(connection_id) {
    return
  }
  let pending : PortForwardTcpPendingOpen = { task: None, closed: false, }
  state.tcp_expose_pending_opens[connection_id] = pending
  let task = ctx.root.spawn(allow_failure=true, () => {
    defer {
      pending.task = None
      forget_port_forward_tcp_pending_open(connection_id, pending)
    }
    let target = target_host + ":" + target_port.to_string()
    let conn = @async.with_timeout(port_forward_tcp_open_timeout_ms, () => {
      @socket.Tcp::connect_to_host(target_host, port=target_port)
    }) catch {
      _ => {
        log_debug(
          "port_forward open tcp connect failed requester=\{ctx.msg.source_id} target=\{target}",
        )
        ignore(
          @async.with_timeout_opt(port_forward_tcp_open_timeout_ms, () => {
            send_port_forward_message_via(
              ctx.msg.source_id,
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
            )
          }),
        )
        return
      }
    }
    defer conn.close()
    // Remote close may race a pending dial. Never publish a late connection.
    if pending.closed {
      return
    }
    let endpoint = new_port_forward_tcp_endpoint(
      conn,
      rule_id~,
      peer_id=ctx.msg.source_id,
      protocol~,
      connection_id~,
      route_protocol=ctx.transport.protocol(),
      route_addr=ctx.sender_addr,
      opened=true,
      audit=record_port_forward_audit_open(
        rule_id,
        protocol,
        ctx.msg.source_id,
        get_config().id,
        target,
      ),
    )
    defer close_port_forward_tcp_endpoint(endpoint)
    state.tcp_expose_connections[connection_id] = endpoint
    forget_port_forward_tcp_pending_open(connection_id, pending)
    pending.task = None
    log_debug(
      "port_forward open tcp established requester=\{ctx.msg.source_id} target=\{target}",
    )
    run_port_forward_tcp_endpoint(endpoint, () => {
      let acked = @async.with_timeout_opt(port_forward_tcp_open_timeout_ms, () => {
        send_port_forward_message_via(
          ctx.msg.source_id,
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
        )
      })
      if acked is Some(true) {
        run_port_forward_tcp_reader(endpoint)
      } else {
        endpoint.error = Some("open_ack_failed")
      }
    })
  })
  if state.tcp_expose_pending_opens.get(connection_id) is Some(current) &&
    physical_equal(current, pending) &&
    !pending.closed {
    pending.task = Some(task)
  }
}
