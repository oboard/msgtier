///|
// Keep the wire limit compatible with peers that still send 4 MiB chunks.
let port_forward_tcp_chunk_size : Int = 4 * 1024 * 1024

///|
let port_forward_tcp_read_buffer_size : Int = 64 * 1024

///|
let port_forward_tcp_max_buffered_bytes : Int = 8 * 1024 * 1024

///|
let port_forward_tcp_max_buffered_chunks : Int = 256

///|
let port_forward_tcp_open_timeout_ms : Int = 5000

///|
let port_forward_tcp_close_timeout_ms : Int = 30000

///|
fn new_port_forward_tcp_endpoint(
  socket : @socket.Tcp,
  rule_id~ : String,
  peer_id~ : String,
  protocol~ : String,
  connection_id~ : String,
  audit~ : PortForwardAuditEntry,
  route_protocol? : String = "",
  route_addr? : String = "",
  opened? : Bool = false,
) -> PortForwardTcpEndpoint {
  {
    socket,
    send_seq: Ref(0),
    recv_next_seq: Ref(0),
    remote_close_seq: Ref(None),
    recv_buffer: Ref(Map([])),
    pending_writes: Ref([]),
    draining: Ref(false),
    closed: Ref(false),
    cond: @cond_var.Cond(),
    buffered_bytes: 0,
    buffered_chunks: 0,
    reader: None,
    writer: None,
    close_timer: None,
    rule_id,
    peer_id,
    protocol,
    connection_id,
    route_protocol,
    route_addr,
    opened,
    failed: false,
    error: None,
    audit,
  }
}

///|
// All exits (EOF, remote close, failure and cancellation) share this cleanup.
// Closing the descriptor alone does not cancel suspended async socket IO.
fn close_port_forward_tcp_endpoint(
  endpoint : PortForwardTcpEndpoint,
  error? : String,
) -> Unit {
  if endpoint.closed.val {
    return
  }
  endpoint.closed.val = true
  if error is Some(reason) {
    endpoint.error = Some(reason)
  }
  forget_port_forward_tcp_endpoint(endpoint)
  endpoint.cond.broadcast()
  if endpoint.reader is Some(task) {
    endpoint.reader = None
    task.cancel()
  }
  if endpoint.writer is Some(task) {
    endpoint.writer = None
    task.cancel()
  }
  if endpoint.close_timer is Some(task) {
    endpoint.close_timer = None
    task.cancel()
  }
  endpoint.socket.close()
  endpoint.recv_buffer.val = Map([])
  endpoint.pending_writes.val = []
  endpoint.buffered_bytes = 0
  endpoint.buffered_chunks = 0
  if endpoint.audit.ended_at is None {
    record_port_forward_audit_close(
      endpoint.audit,
      endpoint.error.unwrap_or("closed"),
    )
  }
}

///|
fn queue_port_forward_tcp_recv_chunk(
  endpoint : PortForwardTcpEndpoint,
  seq : Int,
  data : Bytes,
) -> Bool {
  guard !endpoint.closed.val else { return false }
  if seq < 0 ||
    seq == 0x7fff_ffff ||
    data.is_empty() ||
    data.length() > port_forward_tcp_chunk_size {
    endpoint.error = Some("invalid_data")
    return false
  }
  if seq < endpoint.recv_next_seq.val || endpoint.recv_buffer.val.contains(seq) {
    return true
  }
  if endpoint.remote_close_seq.val is Some(last_seq) && seq > last_seq {
    endpoint.error = Some("data_after_close")
    return false
  }
  // Include out-of-order chunks, queued writes AND the in-flight socket write.
  // The transport dispatch callback cannot suspend to apply backpressure, so
  // reject overflow explicitly instead of retaining an unbounded byte stream.
  if data.length() >
    port_forward_tcp_max_buffered_bytes - endpoint.buffered_bytes ||
    endpoint.buffered_chunks >= port_forward_tcp_max_buffered_chunks {
    endpoint.error = Some("receive_buffer_limit")
    return false
  }
  endpoint.buffered_bytes += data.length()
  endpoint.buffered_chunks += 1
  endpoint.recv_buffer.val[seq] = data
  for ;; {
    let next_seq = endpoint.recv_next_seq.val
    match endpoint.recv_buffer.val.get(next_seq) {
      Some(chunk) => {
        endpoint.recv_buffer.val.remove(next_seq)
        endpoint.pending_writes.val.push(chunk)
        endpoint.recv_next_seq.val = next_seq + 1
      }
      None => break
    }
  }
  true
}

///|
fn should_finalize_port_forward_tcp_remote_close(
  endpoint : PortForwardTcpEndpoint,
) -> Bool {
  match endpoint.remote_close_seq.val {
    Some(last_seq) =>
      !endpoint.closed.val &&
      endpoint.recv_next_seq.val > last_seq &&
      endpoint.buffered_chunks == 0
    None => false
  }
}

///|
async fn run_port_forward_tcp_writer(endpoint : PortForwardTcpEndpoint) -> Unit {
  let finished = Ref(false)
  defer {
    // Break the endpoint -> task -> endpoint reference before any cleanup.
    endpoint.writer = None
    endpoint.draining.val = false
    if !finished.val || should_finalize_port_forward_tcp_remote_close(endpoint) {
      close_port_forward_tcp_endpoint(endpoint)
    }
  }
  while !endpoint.closed.val && !endpoint.pending_writes.val.is_empty() {
    let data = endpoint.pending_writes.val.remove(0)
    endpoint.socket.write(data) catch {
      _ => {
        endpoint.error = Some("write_failed")
        return
      }
    }
    if !endpoint.closed.val {
      endpoint.buffered_bytes -= data.length()
      endpoint.buffered_chunks -= 1
      endpoint.audit.bytes_in += data.length()
    }
  }
  // Do not leave a writer task waiting on every idle connection. The next
  // receive callback starts another writer when there is data to drain.
  finished.val = true
}

///|
fn ensure_port_forward_tcp_writer(
  root : @async.TaskGroup[Unit],
  endpoint : PortForwardTcpEndpoint,
) -> Unit {
  if endpoint.closed.val ||
    endpoint.draining.val ||
    endpoint.pending_writes.val.is_empty() {
    return
  }
  endpoint.draining.val = true
  let task = root.spawn(allow_failure=true, () => {
    run_port_forward_tcp_writer(endpoint)
  })
  // spawn may run the task before returning. Do not retain a completed task.
  if endpoint.draining.val && !endpoint.closed.val {
    endpoint.writer = Some(task)
  }
}

///|
fn receive_port_forward_tcp_chunk(
  root : @async.TaskGroup[Unit],
  endpoint : PortForwardTcpEndpoint,
  seq : Int,
  data : Bytes,
) -> Unit {
  if queue_port_forward_tcp_recv_chunk(endpoint, seq, data) {
    ensure_port_forward_tcp_writer(root, endpoint)
  } else {
    close_port_forward_tcp_endpoint(endpoint)
  }
}

///|
fn receive_port_forward_tcp_close(
  root : @async.TaskGroup[Unit],
  endpoint : PortForwardTcpEndpoint,
  last_seq : Int?,
  error : String?,
  timeout_ms? : Int = port_forward_tcp_close_timeout_ms,
) -> Unit {
  guard !endpoint.closed.val else { return }
  // None on the wire means an empty stream, not "no close received yet".
  let final_seq = last_seq.unwrap_or(-1)
  if final_seq < -1 || final_seq == 0x7fff_ffff {
    close_port_forward_tcp_endpoint(endpoint, error="invalid_close_sequence")
    return
  }
  if endpoint.remote_close_seq.val is Some(previous) {
    if previous != final_seq {
      close_port_forward_tcp_endpoint(endpoint, error="invalid_close_sequence")
    }
    return
  }
  endpoint.remote_close_seq.val = Some(final_seq)
  endpoint.error = error
  endpoint.cond.broadcast()
  if should_finalize_port_forward_tcp_remote_close(endpoint) {
    close_port_forward_tcp_endpoint(endpoint)
    return
  }
  ensure_port_forward_tcp_writer(root, endpoint)
  if endpoint.closed.val {
    return
  }
  // A missing last chunk or a stalled local consumer must not retain a closing
  // connection forever. This deadline does not affect live idle connections.
  let finished = Ref(false)
  let task = root.spawn(no_wait=true, () => {
    defer {
      finished.val = true
      endpoint.close_timer = None
    }
    @async.sleep(timeout_ms)
    endpoint.close_timer = None
    close_port_forward_tcp_endpoint(endpoint, error="close_timeout")
  })
  if !finished.val && !endpoint.closed.val {
    endpoint.close_timer = Some(task)
  }
}

///|
// Own the handshake/reader in a child task so remote close can cancel either.
// The enclosing task remains available to notify the peer after a local error.
async fn run_port_forward_tcp_endpoint(
  endpoint : PortForwardTcpEndpoint,
  run : async () -> Unit,
) -> Unit {
  defer close_port_forward_tcp_endpoint(endpoint)
  @async.with_task_group(group => {
    let finished = Ref(false)
    let task = group.spawn(allow_failure=true, () => {
      defer {
        finished.val = true
        endpoint.reader = None
      }
      if !endpoint.closed.val {
        run()
      }
    })
    if !finished.val && !endpoint.closed.val {
      endpoint.reader = Some(task)
    } else if endpoint.closed.val {
      task.cancel()
    }
    task.wait() catch {
      _ =>
        if !endpoint.closed.val && endpoint.error is None {
          endpoint.error = Some("read_failed")
        }
    }
  })
  close_port_forward_tcp_endpoint(endpoint)
  if endpoint.remote_close_seq.val is None {
    ignore(
      @async.with_timeout_opt(port_forward_tcp_open_timeout_ms, () => {
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
          endpoint.error,
          route_protocol=endpoint.route_protocol,
          route_addr=endpoint.route_addr,
        )
      }),
    )
  }
}
