///|
fn new_port_forward_test_endpoint(
  socket : @socket.Tcp,
  connection_id : String,
) -> PortForwardTcpEndpoint {
  new_port_forward_tcp_endpoint(
    socket,
    rule_id="memory-test",
    peer_id="memory-test-peer-" + connection_id,
    protocol="tcp",
    connection_id~,
    opened=true,
    // No registered transport matches this route; tests cannot contact peers.
    route_protocol="memory-test-unregistered",
    route_addr="unused",
    audit={
      rule_id: "memory-test",
      protocol: "tcp",
      requester_peer_id: "peer",
      expose_peer_id: "local",
      target: "loopback",
      started_at: @env.now(),
      ended_at: None,
      bytes_in: 0,
      bytes_out: 0,
      status: "open",
    },
  )
}

///|
async fn with_port_forward_test_endpoint(
  connection_id : String,
  run : async (@async.TaskGroup[Unit], PortForwardTcpEndpoint, @socket.Tcp) -> Unit,
  forward? : Bool = false,
) -> Unit {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let socket = @socket.Tcp::connect(server.addr)
      defer socket.close()
      let (peer, _) = server.accept()
      defer peer.close()
      let endpoint = new_port_forward_test_endpoint(socket, connection_id)
      if forward {
        port_forward_registry_state.tcp_forward_connections[connection_id] = endpoint
      } else {
        port_forward_registry_state.tcp_expose_connections[connection_id] = endpoint
      }
      defer close_port_forward_tcp_endpoint(endpoint)
      run(group, endpoint, peer)
    })
  })
}

///|
fn port_forward_test_context(
  root : @async.TaskGroup[Unit],
  msg : Message,
) -> MessageContext {
  {
    root,
    transport: MockReplyTransport::{ sent: Ref([]), },
    local_addr: "local",
    sender_addr: "peer",
    my_id: "local",
    msg,
    should_skip_hello_callback: false,
  }
}

///|
fn close_port_forward_test_remote(
  root : @async.TaskGroup[Unit],
  endpoint : PortForwardTcpEndpoint,
  last_seq : Int?,
) -> Unit {
  handle_port_forward_close_message(
    port_forward_test_context(
      root,
      Message(
        kind="port_forward_close",
        source_id=endpoint.peer_id,
        body=make_port_forward_close_body(
          endpoint.rule_id,
          "tcp",
          endpoint.connection_id,
          last_seq,
          None,
        ),
      ),
    ),
  )
}

///|
fn inspect_port_forward_test_closed(
  endpoint : PortForwardTcpEndpoint,
) -> Unit raise {
  inspect(endpoint.closed.val, content="true")
  inspect(endpoint.reader is None, content="true")
  inspect(endpoint.writer is None, content="true")
  inspect(endpoint.close_timer is None, content="true")
  inspect(endpoint.draining.val, content="false")
  inspect(endpoint.recv_buffer.val.length(), content="0")
  inspect(endpoint.pending_writes.val.length(), content="0")
  inspect(endpoint.buffered_bytes, content="0")
  inspect(endpoint.buffered_chunks, content="0")
  inspect(endpoint.audit.ended_at is Some(_), content="true")
  inspect(
    get_port_forward_tcp_forward_connection(endpoint.connection_id) is None,
    content="true",
  )
  inspect(
    get_port_forward_tcp_expose_connection(endpoint.connection_id) is None,
    content="true",
  )
}

///|
async fn test_port_forward_remote_close(after_data : Bool) -> Unit {
  for forward in [false, true] {
    with_port_forward_test_endpoint(
      "memory-close-\{after_data}-\{forward}",
      forward~,
      (group, endpoint, peer) => {
        if after_data {
          inspect(
            queue_port_forward_tcp_recv_chunk(endpoint, 0, b"x"),
            content="true",
          )
          ensure_port_forward_tcp_writer(group, endpoint)
          inspect(peer.read_exactly(1), content="b\"x\"")
          while endpoint.draining.val {
            @async.sleep(1)
          }
          inspect(endpoint.writer is None, content="true")
        }
        close_port_forward_test_remote(
          group,
          endpoint,
          if after_data {
            Some(0)
          } else {
            None
          },
        )
        inspect(peer.read_some() is None, content="true")
        inspect_port_forward_test_closed(endpoint)
      },
    )
  }
}

///|
async test "memory lifecycle: empty port-forward remote close releases endpoint" {
  test_port_forward_remote_close(false)
}

///|
async test "memory lifecycle: port-forward remote close after drained write releases endpoint" {
  test_port_forward_remote_close(true)
}

///|
async test "memory lifecycle: port-forward close drains queued and in-flight legacy chunks" {
  with_port_forward_test_endpoint("memory-close-drain", (group, endpoint, peer) => {
    let data = FixedArray::make(port_forward_tcp_chunk_size, b'x').unsafe_reinterpret_as_bytes()
    inspect(
      queue_port_forward_tcp_recv_chunk(endpoint, 0, data),
      content="true",
    )
    inspect(
      queue_port_forward_tcp_recv_chunk(endpoint, 1, data),
      content="true",
    )
    ensure_port_forward_tcp_writer(group, endpoint)
    @async.sleep(10)
    inspect(endpoint.draining.val, content="true")
    inspect(endpoint.buffered_chunks > 0, content="true")
    close_port_forward_test_remote(group, endpoint, Some(1))
    inspect(endpoint.closed.val, content="false")
    inspect(
      should_finalize_port_forward_tcp_remote_close(endpoint),
      content="false",
    )
    inspect(peer.read_exactly(data.length()) == data, content="true")
    inspect(peer.read_exactly(data.length()) == data, content="true")
    inspect(peer.read_some() is None, content="true")
    while endpoint.draining.val {
      @async.sleep(1)
    }
    inspect(endpoint.audit.bytes_in, content="8388608")
    inspect_port_forward_test_closed(endpoint)
  })
}

///|
async test "memory lifecycle: port-forward close waits for reordered final data" {
  with_port_forward_test_endpoint("memory-close-reordered", (
    group,
    endpoint,
    peer,
  ) => {
    close_port_forward_test_remote(group, endpoint, Some(2))
    inspect(endpoint.closed.val, content="false")
    inspect(endpoint.close_timer is Some(_), content="true")
    dispatch_raw_port_forward_data(group, endpoint.connection_id, 2, b"c")
    dispatch_raw_port_forward_data(group, endpoint.connection_id, 0, b"a")
    dispatch_raw_port_forward_data(group, endpoint.connection_id, 1, b"b")
    inspect(peer.read_exactly(3), content="b\"abc\"")
    inspect(peer.read_some() is None, content="true")
    inspect_port_forward_test_closed(endpoint)
  })
}

///|
async test "memory lifecycle: missing port-forward final data has a bounded close wait" {
  with_port_forward_test_endpoint("memory-close-timeout", (
    group,
    endpoint,
    peer,
  ) => {
    receive_port_forward_tcp_close(
      group,
      endpoint,
      Some(1),
      None,
      timeout_ms=20,
    )
    let timer = endpoint.close_timer.unwrap()
    receive_port_forward_tcp_close(
      group,
      endpoint,
      Some(1),
      None,
      timeout_ms=5000,
    )
    inspect(
      physical_equal(endpoint.close_timer.unwrap(), timer),
      content="true",
    )
    inspect(
      queue_port_forward_tcp_recv_chunk(endpoint, 1, b"unreachable"),
      content="true",
    )
    inspect(peer.read_some() is None, content="true")
    timer.wait()
    inspect(endpoint.audit.status, content="close_timeout")
    inspect_port_forward_test_closed(endpoint)
  })
}

///|
async test "memory lifecycle: port-forward remote close cancels a suspended reader" {
  with_port_forward_test_endpoint("memory-close-reader", (group, endpoint, peer) => {
    let owner = group.spawn(() => {
      run_port_forward_tcp_endpoint(endpoint, () => {
        run_port_forward_tcp_reader(endpoint)
      })
    })
    while endpoint.reader is None {
      @async.sleep(1)
    }
    let reader = endpoint.reader.unwrap()
    close_port_forward_test_remote(group, endpoint, None)
    inspect(peer.read_some() is None, content="true")
    reader.wait() catch {
      _ => ()
    }
    owner.wait()
    inspect_port_forward_test_closed(endpoint)
  })
}

///|
async fn test_cancel_port_forward_owner(handshake : Bool) -> Unit {
  with_port_forward_test_endpoint("memory-cancel-owner-\{handshake}", (
    group,
    endpoint,
    peer,
  ) => {
    endpoint.opened = !handshake
    let owner = group.spawn(() => {
      run_port_forward_tcp_endpoint(endpoint, () => {
        if handshake {
          ignore(wait_port_forward_tcp_open_ack(endpoint))
        } else {
          run_port_forward_tcp_reader(endpoint)
        }
      })
    })
    while endpoint.reader is None {
      @async.sleep(1)
    }
    let reader = endpoint.reader.unwrap()
    inspect(
      queue_port_forward_tcp_recv_chunk(endpoint, 1, b"retained"),
      content="true",
    )
    owner.cancel()
    owner.wait() catch {
      _ => ()
    }
    reader.wait() catch {
      _ => ()
    }
    inspect(peer.read_some() is None, content="true")
    inspect_port_forward_test_closed(endpoint)
  })
}

///|
async test "memory lifecycle: cancelling port-forward during open ack cleans up" {
  test_cancel_port_forward_owner(true)
}

///|
async test "memory lifecycle: cancelling port-forward during socket read cleans up" {
  test_cancel_port_forward_owner(false)
}

///|
async test "memory lifecycle: failed port-forward open ack cancels its owner" {
  with_port_forward_test_endpoint("memory-open-ack-failed", forward=true, (
    group,
    endpoint,
    peer,
  ) => {
    endpoint.opened = false
    let owner = group.spawn(() => {
      run_port_forward_tcp_endpoint(endpoint, () => {
        ignore(wait_port_forward_tcp_open_ack(endpoint))
      })
    })
    while endpoint.reader is None {
      @async.sleep(1)
    }
    mark_port_forward_open_ack(endpoint.connection_id, false, Some("rejected"))
    owner.wait()
    inspect(peer.read_some() is None, content="true")
    inspect(endpoint.audit.status, content="rejected")
    inspect_port_forward_test_closed(endpoint)
  })
}

///|
async test "memory lifecycle: stale port-forward cleanup preserves replacement endpoints" {
  for forward in [false, true] {
    with_port_forward_test_endpoint(
      "memory-stale-endpoint-\{forward}",
      forward~,
      (_, endpoint, _peer) => {
        let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
        defer server.close()
        let conn = @socket.Tcp::connect(server.addr)
        let (peer, _) = server.accept()
        defer peer.close()
        let replacement = new_port_forward_test_endpoint(
          conn,
          endpoint.connection_id,
        )
        defer close_port_forward_tcp_endpoint(replacement)
        let connections = if forward {
          port_forward_registry_state.tcp_forward_connections
        } else {
          port_forward_registry_state.tcp_expose_connections
        }
        connections[endpoint.connection_id] = replacement
        close_port_forward_tcp_endpoint(endpoint, error="original")
        close_port_forward_tcp_endpoint(endpoint, error="late_cleanup")
        inspect(
          physical_equal(connections[endpoint.connection_id], replacement),
          content="true",
        )
        inspect(replacement.closed.val, content="false")
        inspect(endpoint.audit.status, content="original")
        close_port_forward_tcp_endpoint(replacement)
        inspect(peer.read_some() is None, content="true")
      },
    )
  }
}

///|
async test "memory lifecycle: closing a pending port-forward open cancels the dial task" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let connection_id = "memory-pending-open"
      let pending : PortForwardTcpPendingOpen = { task: None, closed: false, }
      port_forward_registry_state.tcp_expose_pending_opens[connection_id] = pending
      defer cancel_port_forward_tcp_pending_open(connection_id)
      let waiting = Ref(false)
      let stopped = Ref(false)
      let cond = @cond_var.Cond()
      let task = group.spawn(() => {
        defer {
          stopped.val = true
          pending.task = None
          forget_port_forward_tcp_pending_open(connection_id, pending)
        }
        waiting.val = true
        cond.wait()
      })
      pending.task = Some(task)
      while !waiting.val {
        @async.sleep(1)
      }
      handle_port_forward_close_message(
        port_forward_test_context(
          group,
          Message(
            kind="port_forward_close",
            source_id="peer",
            body=make_port_forward_close_body(
              "memory-test",
              "tcp",
              connection_id,
              None,
              None,
            ),
          ),
        ),
      )
      task.wait() catch {
        _ => ()
      }
      inspect(pending.closed, content="true")
      inspect(stopped.val, content="true")
      inspect(pending.task is None, content="true")
      inspect(
        port_forward_registry_state.tcp_expose_pending_opens.contains(
          connection_id,
        ),
        content="false",
      )
    })
  })
}

///|
async test "memory lifecycle: repeated port-forward open close leaves no tasks or registrations" {
  for cycle in 0..<128 {
    let connection_id = "memory-repeated-close-\{cycle}"
    with_port_forward_test_endpoint(connection_id, forward=cycle % 2 == 0, (
      group,
      endpoint,
      peer,
    ) => {
      let owner = group.spawn(() => {
        run_port_forward_tcp_endpoint(endpoint, () => {
          run_port_forward_tcp_reader(endpoint)
        })
      })
      while endpoint.reader is None {
        @async.sleep(1)
      }
      if cycle % 2 == 0 {
        dispatch_raw_port_forward_data(group, connection_id, 0, b"response")
        assert_eq(peer.read_exactly(8), b"response")
      }
      close_port_forward_test_remote(
        group,
        endpoint,
        if cycle % 2 == 0 {
          Some(0)
        } else {
          None
        },
      )
      assert_true(peer.read_some() is None)
      owner.wait()
      inspect_port_forward_test_closed(endpoint)
    })
  }
}
