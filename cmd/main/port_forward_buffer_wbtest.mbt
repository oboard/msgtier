///|
async test "memory lifecycle: port-forward reorder buffer has a byte limit" {
  with_port_forward_test_endpoint("memory-buffer-bytes", (group, endpoint, peer) => {
    let data = FixedArray::make(port_forward_tcp_chunk_size, b'x').unsafe_reinterpret_as_bytes()
    inspect(
      queue_port_forward_tcp_recv_chunk(endpoint, 1, data),
      content="true",
    )
    inspect(
      queue_port_forward_tcp_recv_chunk(endpoint, 2, data),
      content="true",
    )
    inspect(endpoint.buffered_bytes, content="8388608")
    inspect(endpoint.buffered_chunks, content="2")
    // Duplicates do not consume more budget or replace retained data.
    inspect(
      queue_port_forward_tcp_recv_chunk(endpoint, 1, b"duplicate"),
      content="true",
    )
    inspect(endpoint.buffered_bytes, content="8388608")
    dispatch_raw_port_forward_data(
      group,
      endpoint.connection_id,
      3,
      b"overflow",
    )
    inspect(endpoint.audit.status, content="receive_buffer_limit")
    inspect(peer.read_some() is None, content="true")
    inspect_port_forward_test_closed(endpoint)
  })
}

///|
async test "memory lifecycle: port-forward tiny chunks have a count limit" {
  with_port_forward_test_endpoint("memory-buffer-count", (group, endpoint, peer) => {
    for seq in 1..<=port_forward_tcp_max_buffered_chunks {
      assert_true(queue_port_forward_tcp_recv_chunk(endpoint, seq, b"x"))
    }
    inspect(endpoint.buffered_chunks, content="256")
    inspect(endpoint.buffered_bytes, content="256")
    handle_port_forward_data_message(
      port_forward_test_context(
        group,
        Message(
          kind="port_forward_data",
          source_id=endpoint.peer_id,
          body=make_port_forward_data_body(
            endpoint.rule_id,
            "tcp",
            endpoint.connection_id,
            257,
          ),
          attachment=b"overflow",
        ),
      ),
    )
    inspect(endpoint.audit.status, content="receive_buffer_limit")
    inspect(peer.read_some() is None, content="true")
    inspect_port_forward_test_closed(endpoint)
  })
}

///|
async test "memory lifecycle: duplicate port-forward chunks are counted and written once" {
  with_port_forward_test_endpoint("memory-buffer-duplicates", (
    group,
    endpoint,
    peer,
  ) => {
    inspect(
      queue_port_forward_tcp_recv_chunk(endpoint, 1, b"b"),
      content="true",
    )
    inspect(
      queue_port_forward_tcp_recv_chunk(endpoint, 1, b"different"),
      content="true",
    )
    inspect(endpoint.buffered_bytes, content="1")
    inspect(endpoint.buffered_chunks, content="1")
    inspect(
      queue_port_forward_tcp_recv_chunk(endpoint, 0, b"a"),
      content="true",
    )
    inspect(
      queue_port_forward_tcp_recv_chunk(endpoint, 0, b"duplicate"),
      content="true",
    )
    inspect(endpoint.buffered_bytes, content="2")
    inspect(endpoint.buffered_chunks, content="2")
    ensure_port_forward_tcp_writer(group, endpoint)
    inspect(peer.read_exactly(2), content="b\"ab\"")
    while endpoint.draining.val {
      @async.sleep(1)
    }
    inspect(endpoint.buffered_bytes, content="0")
    inspect(endpoint.buffered_chunks, content="0")
    inspect(endpoint.writer is None, content="true")
    close_port_forward_test_remote(group, endpoint, Some(1))
    inspect(peer.read_some() is None, content="true")
    inspect_port_forward_test_closed(endpoint)
  })
}

///|
async test "memory lifecycle: invalid port-forward sequence or oversize data is rejected" {
  for
    (seq, data) in [
      (-1, b"x"),
      (0x7fff_ffff, b"x"),
      (
        0,
        FixedArray::make(port_forward_tcp_chunk_size + 1, b'x').unsafe_reinterpret_as_bytes(),
      ),
    ] {
    with_port_forward_test_endpoint("memory-buffer-invalid-\{seq}", (
      group,
      endpoint,
      peer,
    ) => {
      receive_port_forward_tcp_chunk(group, endpoint, seq, data)
      inspect(endpoint.audit.status, content="invalid_data")
      inspect(peer.read_some() is None, content="true")
      inspect_port_forward_test_closed(endpoint)
    })
  }
}

///|
async test "memory lifecycle: data beyond port-forward final sequence closes the stream" {
  with_port_forward_test_endpoint("memory-buffer-after-close", (
    group,
    endpoint,
    peer,
  ) => {
    receive_port_forward_tcp_close(group, endpoint, Some(0), None)
    receive_port_forward_tcp_chunk(group, endpoint, 1, b"unexpected")
    inspect(endpoint.audit.status, content="data_after_close")
    inspect(peer.read_some() is None, content="true")
    inspect_port_forward_test_closed(endpoint)
  })
}

///|
async test "memory lifecycle: cancelling a blocked port-forward writer releases all buffers" {
  with_port_forward_test_endpoint("memory-buffer-cancel-writer", (
    group,
    endpoint,
    _peer,
  ) => {
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
    // Even bytes removed from pending_writes still count until write completes.
    inspect(endpoint.buffered_bytes > 0, content="true")
    let writer = endpoint.writer.unwrap()
    close_port_forward_tcp_endpoint(endpoint)
    writer.wait() catch {
      _ => ()
    }
    inspect_port_forward_test_closed(endpoint)
  })
}

///|
async test "memory lifecycle: port-forward writer failure removes the endpoint" {
  with_port_forward_test_endpoint("memory-buffer-write-failure", (
    group,
    endpoint,
    peer,
  ) => {
    endpoint.socket.close()
    inspect(
      queue_port_forward_tcp_recv_chunk(endpoint, 0, b"unwritable"),
      content="true",
    )
    ensure_port_forward_tcp_writer(group, endpoint)
    while !endpoint.closed.val {
      @async.sleep(1)
    }
    inspect(endpoint.audit.status, content="write_failed")
    inspect(peer.read_some() is None, content="true")
    inspect_port_forward_test_closed(endpoint)
  })
}
