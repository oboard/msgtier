///|
async test "memory lifecycle: slow port-forward sends bound reader buffers and preserve order" {
  with_port_forward_test_endpoint("memory-reader-backpressure", (
    group,
    endpoint,
    peer,
  ) => {
    let data = FixedArray::makei(512 * 1024, i => (i % 251).to_byte()).unsafe_reinterpret_as_bytes()
    let sends_started = Ref(0)
    let bytes_sent = Ref(0)
    let in_flight = Ref(0)
    let max_in_flight = Ref(0)
    let writable = Ref(false)
    let ready = @cond_var.Cond()
    let owner = group.spawn(() => {
      run_port_forward_tcp_endpoint(endpoint, () => {
        run_port_forward_tcp_reader(endpoint, send=(_endpoint, chunk) => {
          sends_started.val += 1
          in_flight.val += 1
          if in_flight.val > max_in_flight.val {
            max_in_flight.val = in_flight.val
          }
          defer {
            in_flight.val -= 1
          }
          while !writable.val {
            ready.wait()
          }
          assert_true(chunk.length() <= port_forward_tcp_read_buffer_size)
          let offset = bytes_sent.val
          assert_eq(chunk, data[offset:offset + chunk.length()].to_owned())
          bytes_sent.val += chunk.length()
          true
        })
      })
    })
    let producer = group.spawn(() => {
      peer.write(data)
      peer.close()
    })
    while sends_started.val == 0 {
      @async.sleep(1)
    }
    @async.sleep(20)
    inspect(sends_started.val, content="1")
    inspect(in_flight.val, content="1")
    inspect(bytes_sent.val, content="0")
    writable.val = true
    ready.broadcast()
    producer.wait()
    owner.wait()
    inspect(max_in_flight.val, content="1")
    inspect(bytes_sent.val, content="524288")
    inspect(endpoint.audit.bytes_out, content="524288")
    inspect(sends_started.val >= 8, content="true")
    inspect_port_forward_test_closed(endpoint)
  })
}

///|
async test "memory lifecycle: port-forward send failure stops reading immediately" {
  with_port_forward_test_endpoint("memory-reader-send-failure", (
    group,
    endpoint,
    peer,
  ) => {
    let sends = Ref(0)
    let owner = group.spawn(() => {
      run_port_forward_tcp_endpoint(endpoint, () => {
        run_port_forward_tcp_reader(endpoint, send=(_, _) => {
          sends.val += 1
          false
        })
      })
    })
    peer.write(b"cannot-forward")
    owner.wait()
    inspect(sends.val, content="1")
    inspect(endpoint.audit.bytes_out, content="0")
    inspect(endpoint.audit.status, content="send_failed")
    inspect(peer.read_some() is None, content="true")
    inspect_port_forward_test_closed(endpoint)
  })
}

///|
async test "memory lifecycle: port-forward failed sends do not advance final sequence" {
  with_port_forward_test_endpoint("memory-send-sequence", (_, endpoint, _) => {
    inspect(
      send_port_forward_tcp_chunks(endpoint, b"no-route"),
      content="false",
    )
    inspect(endpoint.send_seq.val, content="0")
    close_port_forward_tcp_endpoint(endpoint)
    inspect(send_port_forward_tcp_chunks(endpoint, b"closed"), content="false")
    inspect(endpoint.send_seq.val, content="0")
  })
}

///|
async test "memory lifecycle: port-forward remote close during handshake prevents reader start" {
  with_port_forward_test_endpoint("memory-open-close", forward=true, (
    group,
    endpoint,
    peer,
  ) => {
    endpoint.opened = false
    let started_reader = Ref(false)
    let owner = group.spawn(() => {
      run_port_forward_tcp_endpoint(endpoint, () => {
        if wait_port_forward_tcp_open_ack(endpoint) {
          started_reader.val = true
          run_port_forward_tcp_reader(endpoint)
        }
      })
    })
    while endpoint.reader is None {
      @async.sleep(1)
    }
    close_port_forward_test_remote(group, endpoint, None)
    // A delayed ACK must not resurrect the removed endpoint.
    mark_port_forward_open_ack(endpoint.connection_id, true, None)
    owner.wait()
    inspect(started_reader.val, content="false")
    inspect(peer.read_some() is None, content="true")
    inspect_port_forward_test_closed(endpoint)
  })
}
