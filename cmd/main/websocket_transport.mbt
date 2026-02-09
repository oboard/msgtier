///|
struct WebSocketConnWrapper {
  conn : @websocket.Conn
  sending : Ref[Bool]
  broken : Ref[Bool]
}

///|
struct WebSocketTransport {
  server : @http.Server
  connections : Map[String, WebSocketConnWrapper]
  mut handler : ((Bytes, String) -> Unit)?
  mut on_disconnect : ((String) -> Unit)?
  mut root : @async.TaskGroup[Unit]?
  reader_started : Map[String, Bool]
}

///|
fn WebSocketTransport::new(addr_str : String) -> WebSocketTransport raise {
  let addr = @socket.Addr::parse(addr_str) catch {
    e => abort("Invalid address: " + e.to_string())
  }
  {
    server: @http.Server::new(addr, reuse_addr=true),
    connections: {},
    handler: None,
    on_disconnect: None,
    root: None,
    reader_started: {},
  }
}

///|
impl Transport for WebSocketTransport with send(self, target, data) {
  let mut target_clean = target.strip_prefix("ws://").unwrap_or(target)
  if target_clean.has_suffix("/") {
    target_clean = target_clean[0:target_clean.length() - 1]
  }
  let target_key = target_clean.to_string()

  // Retry loop (max 2 attempts)
  for i = 0; i < 2; i = i + 1 {
    try {
      // Get or create connection
      let mut wrapper_opt = self.connections.get(target_key)
      let mut created = false

      if wrapper_opt is None {
        try {
          // Connect if not connected
          let url = "ws://" + target_key
          let ws = @websocket.connect(url)
          let wrapper = WebSocketConnWrapper::{ 
            conn: ws, 
            sending: { val: false },
            broken: { val: false }
          }
          self.connections[target_key] = wrapper
          wrapper_opt = Some(wrapper)
          created = true
        } catch {
          _ => () // Will be handled by next iteration or return false
        }
      }

      match wrapper_opt {
        Some(wrapper) => {
          // Start reader if new connection
          if created {
            if self.reader_started.get(target_key) is None {
              match (self.root, self.handler, self.on_disconnect) {
                (Some(root), Some(handler), Some(on_disconnect)) => {
                  self.reader_started[target_key] = true
                  root.spawn_bg(fn() {
                    try {
                      for {
                        let msg = wrapper.conn.recv()
                        match msg.kind {
                          Text => {
                            let text = msg.read_all().text()
                            handler(@utf8.encode(text), target_key)
                          }
                          Binary => {
                            let bytes = msg.read_all().binary()
                            handler(bytes, target_key)
                          }
                        }
                      }
                    } catch {
                      _ => {
                        // Mark broken on read error too
                        wrapper.broken.val = true
                        self.connections.remove(target_key)
                        self.reader_started.remove(target_key)
                        on_disconnect(target_key)
                      }
                    }
                  })
                }
                _ => ()
              }
            }
          }

          // Send Logic with Spinlock (using Ref[Bool] for shared state)
          while wrapper.sending.val {
            @async.sleep(5)
          }

          // Check if connection broke while we were waiting
          if wrapper.broken.val {
             self.connections.remove(target_key)
             self.reader_started.remove(target_key)
             // Continue to retry loop to create new connection
             continue 
          }

          wrapper.sending.val = true
          try {
            wrapper.conn.send_binary(data)
            wrapper.sending.val = false
            return true
          } catch {
            _ => {
              wrapper.sending.val = false
              wrapper.broken.val = true
              self.connections.remove(target_key)
              self.reader_started.remove(target_key)
              // Continue loop to retry
            }
          }
        }
        None =>
          if i == 1 {
            return false
          }
      }
    } catch {
      _ => {
        self.connections.remove(target_key)
        self.reader_started.remove(target_key)
      }
    }
  }
  false
}

///|
impl Transport for WebSocketTransport with listen(
  self,
  root,
  handler,
  on_disconnect,
) {
  self.handler = Some(handler)
  self.on_disconnect = Some(on_disconnect)
  self.root = Some(root)
  self.server.run_forever(fn(request, _resp, conn) {
    let client_addr = conn.client_addr().to_string()
    try {
      let ws = @websocket.from_http_server(request, conn)
      let wrapper = WebSocketConnWrapper::{ 
        conn: ws, 
        sending: { val: false },
        broken: { val: false }
      }
      self.connections[client_addr] = wrapper
      self.reader_started[client_addr] = true
      defer {
        ws.close()
        wrapper.broken.val = true // Mark as broken on close
        self.connections.remove(client_addr)
        self.reader_started.remove(client_addr)
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
