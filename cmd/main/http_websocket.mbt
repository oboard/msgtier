///|
enum HttpWebSocketFrame {
  Text(String)
  Binary(Bytes)
  Ping
}

///|
struct HttpWebSocketOutput {
  queue : @aqueue.Queue[(HttpWebSocketFrame, Int)]
  ws : @websocket.Conn
  mut pending_bytes : Int
  mut closed : Bool
}

///|
fn HttpWebSocketOutput::close(self : HttpWebSocketOutput) -> Unit {
  if !self.closed {
    self.closed = true
    self.pending_bytes = 0
    self.queue.close(clear=true)
    self.ws.close()
  }
}

///|
fn HttpWebSocketOutput::enqueue(
  self : HttpWebSocketOutput,
  frame : HttpWebSocketFrame,
) -> Unit {
  if self.closed { return }
  let size = match frame {
    Text(text) => text.length() * 2
    Binary(bytes) => bytes.length()
    Ping => 1
  }
  if size > 4194304 - self.pending_bytes {
    self.close()
    return
  }
  if (self.queue.try_put((frame, size)) catch { _ => false }) {
    self.pending_bytes += size
  } else {
    self.close()
  }
}

///|
/// Keep mocket's chat subscriptions while using a streaming HTTP listener.
/// One connection-scoped writer preserves frame ordering; a slow/disconnected
/// browser cannot retain an unbounded queue or leave an orphan writer task.
async fn serve_http_websocket(
  app : @mocket.App,
  path : String,
  request : @http.Request,
  conn : @http.ServerConnection,
) -> Unit {
  let handler = match app.ws_static_routes.get(path) {
    Some(handler) => handler
    None => {
      send_http_response(conn, request, @mocket.HttpResponse(NotFound).body("Not Found"))
      conn.close()
      return
    }
  }
  let ws = @websocket.from_http_server(request, conn)
  defer conn.close()
  let output : HttpWebSocketOutput = {
    queue: @aqueue.Queue(kind=Blocking(64)),
    ws,
    pending_bytes: 0,
    closed: false,
  }
  defer output.close()
  let id = @nanoid.nanoid().unwrap_or(@env.now().to_string())
  @mocket.register_ws_connection(
    id,
    text => output.enqueue(Text(text)),
    bytes => output.enqueue(Binary(bytes)),
    () => output.enqueue(Ping),
  )
  defer @mocket.unregister_ws_connection(id)
  let peer : @mocket.WebSocketPeer = { connection_id: id, subscribed_channels: [] }
  defer handler(Close(peer))
  handler(Open(peer))
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      for ;; {
        let (frame, size) = output.queue.get()
        match frame {
          Text(text) => ws.send_text(text)
          Binary(bytes) => ws.send_binary(bytes)
          Ping => ws.ping()
        }
        if !output.closed { output.pending_bytes -= size }
      }
    })
    for ;; {
      let message = ws.recv()
      let data = read_http_control_body(message, http_control_body_limit)
      match message.kind {
        Text => handler(Message(peer, Text(@utf8.decode_lossy(data))))
        Binary => handler(Message(peer, Binary(data)))
      }
    }
  }) catch {
    @websocket.ConnectionClosed(_, _) => ()
    @aqueue.QueueAlreadyClosed => ()
    err => raise err
  }
}
