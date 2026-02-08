///|
struct WebSocketConnWrapper {
  conn : @websocket.Conn
  mut sending : Bool
}

///|
struct WebSocketTransport {
  server : @http.Server
  connections : Map[StringView, WebSocketConnWrapper]
}

///|
fn WebSocketTransport::new(addr_str : String) -> WebSocketTransport raise {
  let addr = @socket.Addr::parse(addr_str) catch {
    e => abort("Invalid address: " + e.to_string())
  }
  { server: @http.Server::new(addr, reuse_addr=true), connections: {} }
}

///|
impl Transport for WebSocketTransport with send(self, target, data) {
  let mut target_clean = target.strip_prefix("ws://").unwrap_or(target)
  if target_clean.has_suffix("/") {
    target_clean = target_clean[0:target_clean.length() - 1]
  }
  match self.connections.get(target_clean) {
    Some(wrapper) => {
      // Simple async spinlock to ensure we don't start a new message 
      // before the last one ends (which causes runtime error)
      while wrapper.sending {
        @async.sleep(5)
      }
      wrapper.sending = true
      try {
        wrapper.conn.send_binary(data)
        wrapper.sending = false
        true
      } catch {
        _ => {
          wrapper.sending = false
          self.connections.remove(target_clean)
          false
        }
      }
    }
    None => {
      // Try to connect if not connected
      let url = "ws://" + target_clean.to_string()
      try {
        let ws = @websocket.connect(url)
        let wrapper = WebSocketConnWrapper::{ conn: ws, sending: true }
        self.connections[target_clean] = wrapper
        ws.send_binary(data)
        wrapper.sending = false
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
      self.connections[client_addr] = { conn: ws, sending: false }
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
  self.server.addr().to_string()
}

///|
impl Transport for WebSocketTransport with protocol(_self) {
  "ws"
}

///|
impl Transport for WebSocketTransport with protocol_type(_self) {
  Ws
}

///|
impl Transport for WebSocketTransport with local_address(self) {
  let addr_str = "ws://" + self.server.addr().to_string()
  Address::parse(addr_str) catch {
    _ => abort("Invalid local address: " + addr_str)
  }
}
