///|
async test "memory lifecycle: outgoing raw TCP reader closes its socket" {
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
      ignore(conn.read_exactly(11))
      conn.write(b"\x00\x00\x00\x00")
      let closed = @async.with_timeout_opt(1000, () => conn.read_some())
      inspect(closed is Some(None), content="true")
    })
    inspect(
      Transport::send_raw_port_forward(
        transport,
        server.addr.to_string(),
        "c",
        0,
        b"x",
      ),
      content="true",
    )
    accepted.wait()
    inspect(transport.connections.length(), content="0")
    inspect(transport.reader_started.length(), content="0")
  })
}

///|
async test "memory lifecycle: disconnect cancels an outgoing TCP reader" {
  @async.with_timeout(5000, () => {
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
        inspect(conn.read_some() is None, content="true")
      })
      let target = server.addr.to_string()
      inspect(Transport::send(transport, target, b"x"), content="true")
      let wrapper = transport.connections[target]
      transport.close_connection(target, wrapper.socket)
      accepted.wait()
      inspect(wrapper.reader is None, content="true")
      inspect(transport.connections.length(), content="0")
    })
  })
}

///|
async test "memory lifecycle: stale TCP cleanup preserves replacement" {
  let transport = TcpTransport("127.0.0.1:0")
  defer transport.server.close()
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  let old = @socket.Tcp::connect(server.addr)
  defer old.close()
  let (old_peer, _) = server.accept()
  defer old_peer.close()
  let replacement = @socket.Tcp::connect(server.addr)
  defer replacement.close()
  let (new_peer, _) = server.accept()
  defer new_peer.close()
  let target = server.addr.to_string()
  transport.connections[target] = {
    socket: replacement,
    sending: Ref(false),
    reader: None,
  }
  transport.reader_started[target] = true
  let disconnected = Ref(0)
  transport.on_disconnect = Some(_ => disconnected.val += 1)
  transport.forget_connection(target, old)
  inspect(
    physical_equal(transport.connections[target].socket, replacement),
    content="true",
  )
  inspect(transport.reader_started.contains(target), content="true")
  inspect(disconnected.val, content="0")
  transport.forget_connection(target, replacement)
  inspect(transport.connections.length(), content="0")
  inspect(disconnected.val, content="1")
}

///|
async fn test_outgoing_websocket_close(raw : Bool) -> Unit {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let transport = WebSocketTransport("127.0.0.1:0")
      defer transport.server.close()
      transport.root = Some(group)
      transport.on_disconnect = Some(_ => ())
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let accepted = group.spawn(() => {
        let (conn, _) = server.accept()
        defer conn.close()
        let http = @http.ServerConnection::new(conn)
        let request = http.read_request()
        let ws = @websocket.from_http_server(request, http)
        ignore(ws.recv().read_all())
        ws.send_close()
        let closed = @async.with_timeout_opt(1000, () => {
          while conn.read_some() is Some(_) {
            ()
          }
          true
        })
        inspect(closed is Some(true), content="true")
      })
      let target = server.addr.to_string()
      let sent = if raw {
        Transport::send_raw_port_forward(transport, target, "c", 0, b"x")
      } else {
        Transport::send(transport, target, b"x")
      }
      inspect(sent, content="true")
      accepted.wait()
      inspect(transport.connections.length(), content="0")
      inspect(transport.reader_started.length(), content="0")
    })
  })
}

///|
async test "memory lifecycle: outgoing WebSocket reader closes its socket" {
  test_outgoing_websocket_close(false)
}

///|
async test "memory lifecycle: outgoing raw WebSocket reader closes its socket" {
  test_outgoing_websocket_close(true)
}

///|
async test "memory lifecycle: cancelled TCP listener releases callbacks" {
  @async.with_task_group(group => {
    let transport = TcpTransport("127.0.0.1:0")
    Transport::set_raw_data_handler(transport, (_, _, _) => {
      ignore(Transport::protocol(transport))
    })
    ignore(
      @async.with_timeout_opt(20, () => {
        Transport::listen(
          transport,
          group,
          (_, _) => ignore(Transport::protocol(transport)),
          _ => (),
        )
      }),
    )
    inspect(transport.handler is None, content="true")
    inspect(transport.raw_data_handler is None, content="true")
    inspect(transport.on_disconnect is None, content="true")
    inspect(transport.root is None, content="true")
  })
}

///|
async test "memory lifecycle: cancelled WebSocket listener releases callbacks" {
  @async.with_task_group(group => {
    let transport = WebSocketTransport("127.0.0.1:0")
    Transport::set_raw_data_handler(transport, (_, _, _) => {
      ignore(Transport::protocol(transport))
    })
    ignore(
      @async.with_timeout_opt(20, () => {
        Transport::listen(
          transport,
          group,
          (_, _) => ignore(Transport::protocol(transport)),
          _ => (),
        )
      }),
    )
    inspect(transport.handler is None, content="true")
    inspect(transport.raw_data_handler is None, content="true")
    inspect(transport.on_disconnect is None, content="true")
    inspect(transport.root is None, content="true")
  })
}

///|
async test "memory lifecycle: disconnect cancels an accepted TCP reader" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let transport = TcpTransport("127.0.0.1:0")
      group.spawn_bg(no_wait=true, () => {
        Transport::listen(transport, group, (_, _) => (), _ => ())
      })
      let client = @socket.Tcp::connect(transport.server.addr)
      defer client.close()
      let target = client.addr.to_string()
      while !transport.connections.contains(target) {
        @async.sleep(1)
      }
      let wrapper = transport.connections[target]
      let reader = wrapper.reader.unwrap()
      transport.close_connection(target, wrapper.socket)
      inspect(client.read_some() is None, content="true")
      reader.wait() catch {
        _ => ()
      }
      inspect(wrapper.reader is None, content="true")
      inspect(transport.connections.length(), content="0")
    })
  })
}

///|
async test "memory lifecycle: disconnect cancels an accepted WebSocket reader" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let transport = WebSocketTransport("127.0.0.1:0")
      group.spawn_bg(no_wait=true, () => {
        Transport::listen(transport, group, (_, _) => (), _ => ())
      })
      let client = @websocket.connect(
        "ws://" + transport.server.addr.to_string(),
      )
      defer client.close()
      while transport.connections.is_empty() {
        @async.sleep(1)
      }
      let (target, wrapper) = transport.connections.to_array()[0]
      let reader = wrapper.reader.unwrap()
      transport.close_connection(target, wrapper)
      try ignore(client.recv()) catch {
        _ => ()
      } noraise {
        _ => fail("expected the accepted websocket to close")
      }
      reader.wait() catch {
        _ => ()
      }
      inspect(wrapper.reader is None, content="true")
      inspect(transport.connections.length(), content="0")
    })
  })
}

///|
async fn test_closed_transport_no_reconnect(
  transport : &Transport,
  peer : &Transport,
) -> Unit {
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => peer.listen(group, (_, _) => (), _ => ()))
    ignore(
      @async.with_timeout_opt(20, () => {
        transport.listen(group, (_, _) => (), _ => ())
      }),
    )
    let target = peer.protocol() + "://" + peer.local_addr()
    inspect(transport.send(target, b"x"), content="false")
    inspect(
      transport.send_raw_port_forward(target, "c", 0, b"x"),
      content="false",
    )
  })
}

///|
async test "memory lifecycle: closed transport TCP cannot reconnect" {
  test_closed_transport_no_reconnect(
    TcpTransport("127.0.0.1:0"),
    TcpTransport("127.0.0.1:0"),
  )
}

///|
async test "memory lifecycle: closed transport WebSocket cannot reconnect" {
  test_closed_transport_no_reconnect(
    WebSocketTransport("127.0.0.1:0"),
    WebSocketTransport("127.0.0.1:0"),
  )
}

///|
async fn test_websocket_listener_stops_during_dial(raw : Bool) -> Unit {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let transport = WebSocketTransport("127.0.0.1:0")
      let listener = group.spawn(() => {
        Transport::listen(transport, group, (_, _) => (), _ => ())
      })
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let request_received = Ref(false)
      let complete_handshake = Ref(false)
      let accepted = group.spawn(() => {
        let (conn, _) = server.accept()
        defer conn.close()
        let http = @http.ServerConnection::new(conn)
        let request = http.read_request()
        request_received.val = true
        while !complete_handshake.val {
          @async.sleep(1)
        }
        let ws = @websocket.from_http_server(request, http)
        defer ws.close()
        inspect(conn.read_some() is None, content="true")
      })
      let target = server.addr.to_string()
      let sender = group.spawn(() => {
        if raw {
          Transport::send_raw_port_forward(transport, target, "c", 0, b"x")
        } else {
          Transport::send(transport, target, b"x")
        }
      })
      while !request_received.val {
        @async.sleep(1)
      }
      // Keep the handshake pending until listener cleanup has finished.
      listener.cancel()
      listener.wait() catch {
        _ => ()
      }
      inspect(transport.closed, content="true")
      complete_handshake.val = true
      inspect(sender.wait(), content="false")
      accepted.wait()
      inspect(transport.connections.length(), content="0")
      inspect(transport.reader_started.length(), content="0")
    })
  })
}

///|
async test "memory lifecycle: WebSocket handshake cannot outlive its listener" {
  test_websocket_listener_stops_during_dial(false)
}

///|
async test "memory lifecycle: raw WebSocket handshake cannot outlive its listener" {
  test_websocket_listener_stops_during_dial(true)
}
