///|
struct WebSocketTransport {
  server : @http.Server
  connections : Map[StringView, @websocket.Conn]
}

///|
pub fn WebSocketTransport::new(addr_str : String) -> WebSocketTransport raise {
  let addr = @socket.Addr::parse(addr_str) catch {
    e => abort("Invalid address: " + e.to_string())
  }
  { server: @http.Server::new(addr), connections: {} }
}

///|
impl Transport for WebSocketTransport with send(self, target, data) {
  let mut target_clean = target.strip_prefix("ws://").unwrap_or(target)
  if target_clean.has_suffix("/") {
    target_clean = target_clean[0:target_clean.length() - 1]
  }
  match self.connections.get(target_clean) {
    Some(ws) =>
      try {
        ws.send_binary(data)
        true
      } catch {
        _ => {
          self.connections.remove(target_clean)
          false
        }
      }
    None => {
      // Try to connect if not connected
      let url = "ws://" + target_clean.to_string()
      try {
        let ws = @websocket.connect(url)
        self.connections[target_clean] = ws
        ws.send_binary(data)
        true
      } catch {
        _ => false
      }
    }
  }
}

///|
impl Transport for WebSocketTransport with listen(
  self,
  _root,
  handler,
  on_disconnect,
) {
  self.server.run_forever(fn(request, _resp, conn) {
    let client_addr = conn.client_addr().to_string()
    try {
      let ws = @websocket.from_http_server(request, conn)
      self.connections[client_addr] = ws
      defer {
        ws.close()
        self.connections.remove(client_addr)
        on_disconnect(client_addr)
      }
      for {
        let msg = ws.recv()
        match msg.kind {
          Text => {
            let text = msg.read_all().text()
            handler(@utf8.encode(text), client_addr)
          }
          Binary => {
            let bytes = msg.read_all().binary()
            handler(bytes, client_addr)
          }
        }
      }
    } catch {
      _ => ()
    }
  })
}

///|
impl Transport for WebSocketTransport with local_addr(self) {
  "ws://" + self.server.addr().to_string()
}

///|
impl Transport for WebSocketTransport with protocol(_self) {
  "ws"
}
