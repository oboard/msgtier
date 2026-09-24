///|
test "memory lifecycle: received message IDs expire" {
  let now = @env.now()
  let id = "memory-expired-received"
  server_state.received_message_cache[id] = now - 30001UL
  defer server_state.received_message_cache.remove(id)
  inspect(check_and_mark_received(id, now), content="false")
  inspect(check_and_mark_received(id, now), content="true")
}

///|
test "memory lifecycle: benchmark trace has a bounded backlog" {
  ignore(bench_trace_buffer.take())
  defer ignore(bench_trace_buffer.take())
  for i in 0..<10000 {
    log_bench("memory-test", details=i.to_string())
  }
  inspect(bench_trace_buffer.lines.length() <= 1024, content="true")
}

///|
test "memory lifecycle: timed out messages release send records" {
  reset_pending_state()
  defer reset_pending_state()
  let msg = Message(
    id="memory-expired-pending",
    kind="text",
    source_id="src",
    timestamp=@env.now() - 60000UL,
  )
  add_pending_message(msg)
  record_message_sent(msg.id, "dst", "tcp")
  record_message_sent(msg.id, "dst", "udp")
  inspect(take_pending_messages(_ => true).length(), content="0")
  inspect(pending_state.send_times.length(), content="0")
}

///|
test "memory lifecycle: replaced sync messages release send records" {
  reset_pending_state()
  defer reset_pending_state()
  let old = Message(
    id="memory-old-sync",
    kind="sync",
    source_id="src",
    target_id="dst",
  )
  let replacement = Message(
    id="memory-new-sync",
    kind="sync",
    source_id="src",
    target_id="dst",
  )
  add_pending_message(old)
  record_message_sent(old.id, "dst", "tcp")
  add_pending_message(replacement)
  inspect(pending_state.messages.length(), content="1")
  inspect(pending_state.send_times.length(), content="0")
}

///|
async test "memory lifecycle: cancelled response wait releases request" {
  let id = "memory-cancelled-request"
  add_pending_request(id)
  defer request_tracker_state.tracker.pending.remove(id)
  ignore(
    @async.with_timeout_opt(10, () => ignore(wait_for_response(id, 10000U))),
  )
  inspect(request_tracker_state.tracker.pending.contains(id), content="false")
}

///|
async test "memory lifecycle: outgoing TCP reader closes invalid frame socket" {
  @async.with_task_group(group => {
    let transport = TcpTransport("127.0.0.1:0")
    defer transport.server.close()
    transport.root = Some(group)
    transport.on_disconnect = Some(_ => ())
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let accepted = group.spawn(() => {
      let (conn, _) = server.accept()
      defer conn.close()
      ignore(conn.read_exactly(5))
      conn.write(b"\x00\x00\x00\x00")
      let closed = @async.with_timeout_opt(1000, () => conn.read_some())
      inspect(closed is Some(None), content="true")
    })
    inspect(
      Transport::send(transport, server.addr.to_string(), b"x"),
      content="true",
    )
    accepted.wait()
  })
}

///|
test "memory lifecycle: cache pruning preserves TTL boundaries" {
  server_state.received_message_cache.clear()
  global_state.hello_times.clear()
  global_state.hello_callback_times.clear()
  defer {
    server_state.received_message_cache.clear()
    global_state.hello_times.clear()
    global_state.hello_callback_times.clear()
  }
  server_state.received_message_cache["expired"] = 69999UL
  server_state.received_message_cache["boundary"] = 70000UL
  server_state.received_message_cache["fresh"] = 99999UL
  global_state.hello_times["expired"] = 94999UL
  global_state.hello_times["boundary"] = 95000UL
  global_state.hello_callback_times["expired"] = 99999UL
  global_state.hello_callback_times["boundary"] = 100000UL
  global_state.hello_callback_times["long-ttl"] = 120000UL
  prune_message_caches(100000UL)
  inspect(server_state.received_message_cache.length(), content="2")
  inspect(
    server_state.received_message_cache.contains("expired"),
    content="false",
  )
  inspect(global_state.hello_times.length(), content="1")
  inspect(global_state.hello_callback_times.length(), content="2")
  prune_message_caches(130000UL)
  inspect(server_state.received_message_cache.length(), content="0")
  inspect(global_state.hello_times.length(), content="0")
  inspect(global_state.hello_callback_times.length(), content="0")
}

///|
test "memory lifecycle: hello callback cleanup respects custom TTL" {
  let key = "memory-custom-hello-ttl"
  defer global_state.hello_callback_times.remove(key)
  inspect(check_and_mark_hello(key, 20000UL), content="false")
  prune_message_caches(@env.now() + 6000UL)
  inspect(check_and_mark_hello(key, 20000UL), content="true")
  prune_message_caches(@env.now() + 21000UL)
  inspect(global_state.hello_callback_times.contains(key), content="false")
}

///|
test "memory lifecycle: repeated cache and trace batches release entries" {
  server_state.received_message_cache.clear()
  global_state.hello_times.clear()
  global_state.hello_callback_times.clear()
  defer {
    server_state.received_message_cache.clear()
    global_state.hello_times.clear()
    global_state.hello_callback_times.clear()
  }
  let buffer = BenchTraceBuffer::new()
  for batch in 0..<100 {
    let now = 100000UL + batch.to_uint64() * 31000UL
    for i in 0..<2000 {
      let id = "memory-batch-\{batch}-\{i}"
      server_state.received_message_cache[id] = now
      global_state.hello_times[id] = now
      global_state.hello_callback_times[id] = now + 5000UL
      buffer.push(id)
    }
    assert_eq(buffer.lines.length(), 1024)
    ignore(buffer.take())
    prune_message_caches(now + 30001UL)
    assert_eq(server_state.received_message_cache.length(), 0)
    assert_eq(global_state.hello_times.length(), 0)
    assert_eq(global_state.hello_callback_times.length(), 0)
    assert_eq(buffer.size_chars, 0)
  }
  inspect(buffer.lines.length(), content="0")
}

///|
test "memory lifecycle: trace backlog is bounded by size as well as count" {
  let buffer = BenchTraceBuffer::new()
  let large_line = "x".repeat(128 * 1024)
  buffer.push(large_line)
  buffer.push("overflow")
  inspect(buffer.lines.length(), content="1")
  inspect(buffer.size_chars, content="131072")
  ignore(buffer.take())
  buffer.push(large_line + "overflow")
  inspect(buffer.lines.length(), content="0")
  inspect(buffer.size_chars, content="0")
  buffer.push("next batch")
  inspect(buffer.take().length(), content="1")
  inspect(buffer.lines.length(), content="0")
}

///|
async test "memory lifecycle: trace flush appends and releases failed batches" {
  let path = ".msgtier-memory-trace-" + @nanoid.nanoid().unwrap()
  @fs.write_file(path, b"first\n", create_mode=@fs.CreateNew)
  defer (@fs.remove(path) catch { _ => () })
  let buffer = BenchTraceBuffer::new()
  buffer.push("second\n")
  flush_bench_trace(buffer, path)
  buffer.push("third\n")
  flush_bench_trace(buffer, path)
  inspect(@fs.read_file(path).text(), content="first\nsecond\nthird\n")
  inspect(buffer.lines.length(), content="0")
  inspect(buffer.size_chars, content="0")
  buffer.push("failed batch\n")
  // `path` is a regular file, so opening a child path must fail.
  flush_bench_trace(buffer, path + "/missing")
  inspect(buffer.lines.length(), content="0")
  inspect(buffer.size_chars, content="0")
}

///|
async test "memory lifecycle: idle cache entries are pruned without traffic" {
  let id = "memory-idle-cache"
  server_state.received_message_cache[id] = @env.now() - 30001UL
  defer server_state.received_message_cache.remove(id)
  ignore(
    @async.with_timeout_opt(1200, () => {
      @async.with_task_group(group => start_message_cache_cleanup(group))
    }),
  )
  inspect(server_state.received_message_cache.contains(id), content="false")
}
