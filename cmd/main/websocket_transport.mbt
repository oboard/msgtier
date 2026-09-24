///|
struct WebSocketConnWrapper {
  conn : @websocket.Conn
  sending : Ref[Bool]
  broken : Ref[Bool]
  mut reader : @async.Task[Unit]?
}

///|
struct WebSocketTransport {
  server : @http.Server
  connections : Map[String, WebSocketConnWrapper]
  mut handler : ((Bytes, String) -> Unit)?
  mut raw_data_handler : ((String, Int, Bytes) -> Unit)?
  mut on_disconnect : ((String) -> Unit)?
  mut root : @async.TaskGroup[Unit]?
  mut closed : Bool
  reader_started : Map[String, Bool]
}

///|
async fn WebSocketTransport::WebSocketTransport(
  addr_str : String,
) -> WebSocketTransport {
  let addr = @socket.Addr::parse(addr_str) catch {
    e => abort("Invalid address: " + e.to_string())
  }
  {
    server: @http.Server(addr, reuse_addr=true),
    connections: Map([]),
    handler: None,
    raw_data_handler: None,
    on_disconnect: None,
    root: None,
    closed: false,
    reader_started: Map([]),
  }
}

///|
// Dispatch a received binary WebSocket frame.
// Normal frames: first byte is 0x00 (high byte of 4-byte msgpack length, always 0 for <16MB payloads).
// Raw frames:    first byte is 0x01, followed by [connection_id]['\x00'][4-byte seq BE][data].
fn WebSocketTransport::dispatch_ws_frame(
  self : WebSocketTransport,
  bytes : Bytes,
  sender_addr : String,
) -> Unit {
  if bytes.length() == 0 {
    return
  }
  if bytes[0] == b'\x01' {
    // Raw port-forward data frame
    match self.raw_data_handler {
      None => ()
      Some(raw_handler) => {
        let mut sep = -1
        for i = 1; i < bytes.length(); i = i + 1 {
          if bytes[i] == b'\x00' {
            sep = i
            break
          }
        }
        if sep < 1 || sep + 5 > bytes.length() {
          return
        }
        let connection_id = @utf8.decode(slice_bytes(bytes, 1, sep)) catch {
          _ => return
        }
        let seq = (bytes[sep + 1].to_int() << 24) |
          (bytes[sep + 2].to_int() << 16) |
          (bytes[sep + 3].to_int() << 8) |
          bytes[sep + 4].to_int()
        let data = bytes[sep + 5:]
        raw_handler(connection_id, seq, data.to_owned())
      }
    }
  } else {
    match self.handler {
      Some(handler) => handler(bytes, sender_addr)
      None => ()
    }
  }
}

///|
fn WebSocketTransport::forget_connection(
  self : WebSocketTransport,
  target : String,
  wrapper : WebSocketConnWrapper,
) -> Unit {
  if self.connections.get(target) is Some(current) &&
    physical_equal(current, wrapper) {
    self.connections.remove(target)
    self.reader_started.remove(target)
    if self.on_disconnect is Some(callback) {
      callback(target)
    }
  }
}

///|
fn WebSocketTransport::close_connection(
  self : WebSocketTransport,
  target : String,
  wrapper : WebSocketConnWrapper,
) -> Unit {
  wrapper.broken.val = true
  if wrapper.reader is Some(task) {
    wrapper.reader = None
    task.cancel()
  }
  wrapper.conn.close()
  self.forget_connection(target, wrapper)
}

///|
impl Transport for WebSocketTransport with fn send(self, target, data) {
  if self.closed {
    return false
  }
  let mut target_clean = target.strip_prefix("ws://").unwrap_or(target)
  if target_clean.has_suffix("/") {
    target_clean = target_clean[0:target_clean.length() - 1]
  }
  let target_key = target_clean.to_owned()

  for i = 0; i < 2; i = i + 1 {
    if self.closed {
      return false
    }
    let mut wrapper_opt = self.connections.get(target_key)
    let mut created = false
    if wrapper_opt is None {
      try {
        let url = "ws://" + target_key
        let ws = @async.with_timeout(5000, () => @websocket.connect(url))
        // Handshake completion must not resurrect a stopped transport.
        if self.closed {
          ws.close()
          return false
        }
        match self.connections.get(target_key) {
          Some(existing) => {
            ws.close()
            wrapper_opt = Some(existing)
          }
          None => {
            let wrapper = WebSocketConnWrapper::{
              conn: ws,
              sending: { val: false, },
              broken: { val: false, },
              reader: None,
            }
            self.connections[target_key] = wrapper
            wrapper_opt = Some(wrapper)
            created = true
          }
        }
      } catch {
        _ => ()
      }
    }
    match wrapper_opt {
      Some(wrapper) => {
        if created {
          if self.reader_started.get(target_key) is None {
            match (self.root, self.on_disconnect) {
              (Some(root), Some(_)) => {
                self.reader_started[target_key] = true
                let transport = self
                let task = root.spawn(() => {
                  defer {
                    wrapper.reader = None
                    wrapper.broken.val = true
                    wrapper.conn.close()
                    transport.forget_connection(target_key, wrapper)
                  }
                  try {
                    for ;; {
                      let msg = wrapper.conn.recv()
                      match msg.kind {
                        Text => {
                          let text = msg.read_all().text()
                          transport.dispatch_ws_frame(
                            @utf8.encode(text),
                            target_key,
                          )
                        }
                        Binary => {
                          let bytes = msg.read_all().binary()
                          transport.dispatch_ws_frame(bytes, target_key)
                        }
                      }
                    }
                  } catch {
                    _ => ()
                  }
                })
                if !wrapper.broken.val {
                  wrapper.reader = Some(task)
                }
              }
              _ => ()
            }
          }
        }

        while wrapper.sending.val && !self.closed {
          @async.sleep(5)
        }

        if self.closed {
          return false
        }
        if wrapper.broken.val {
          self.close_connection(target_key, wrapper)
          continue
        }
        wrapper.sending.val = true
        defer {
          wrapper.sending.val = false
        }
        try {
          wrapper.conn.send_binary(data)
          wrapper.sending.val = false
          return true
        } catch {
          _ => {
            wrapper.sending.val = false
            self.close_connection(target_key, wrapper)
          }
        }
      }
      None => if i == 1 { return false }
    }
  }
  false
}

///|
impl Transport for WebSocketTransport with fn send_raw_port_forward(
  self,
  target,
  connection_id,
  seq,
  data,
) {
  if self.closed {
    return false
  }
  let mut target_clean = target.strip_prefix("ws://").unwrap_or(target)
  if target_clean.has_suffix("/") {
    target_clean = target_clean[0:target_clean.length() - 1]
  }
  let target_key = target_clean.to_owned()

  let id_bytes = @utf8.encode(connection_id)
  let id_len = id_bytes.length()
  // Raw WS frame: [0x01][connection_id]['\x00'][4-byte seq BE][data]
  let frame_len = 1 + id_len + 1 + 4 + data.length()
  let frame = FixedArray::make(frame_len, b'\x00')
  frame[0] = b'\x01'
  frame.blit_from_bytes(1, id_bytes, 0, id_len)
  // byte [1 + id_len] stays 0x00 (null separator)
  frame[1 + id_len + 1] = (seq >> 24).to_byte()
  frame[1 + id_len + 2] = (seq >> 16).to_byte()
  frame[1 + id_len + 3] = (seq >> 8).to_byte()
  frame[1 + id_len + 4] = seq.to_byte()
  frame.blit_from_bytes(1 + id_len + 5, data, 0, data.length())
  let frame_bytes = frame.unsafe_reinterpret_as_bytes()

  for i = 0; i < 2; i = i + 1 {
    if self.closed {
      return false
    }
    let mut wrapper_opt = self.connections.get(target_key)
    let mut created = false
    if wrapper_opt is None {
      try {
        let url = "ws://" + target_key
        let ws = @async.with_timeout(5000, () => @websocket.connect(url))
        // Handshake completion must not resurrect a stopped transport.
        if self.closed {
          ws.close()
          return false
        }
        match self.connections.get(target_key) {
          Some(existing) => {
            ws.close()
            wrapper_opt = Some(existing)
          }
          None => {
            let wrapper = WebSocketConnWrapper::{
              conn: ws,
              sending: { val: false, },
              broken: { val: false, },
              reader: None,
            }
            self.connections[target_key] = wrapper
            wrapper_opt = Some(wrapper)
            created = true
          }
        }
      } catch {
        _ => ()
      }
    }
    match wrapper_opt {
      Some(wrapper) => {
        if created {
          if self.reader_started.get(target_key) is None {
            match (self.root, self.on_disconnect) {
              (Some(root), Some(_)) => {
                self.reader_started[target_key] = true
                let transport = self
                let task = root.spawn(() => {
                  defer {
                    wrapper.reader = None
                    wrapper.broken.val = true
                    wrapper.conn.close()
                    transport.forget_connection(target_key, wrapper)
                  }
                  try {
                    for ;; {
                      let msg = wrapper.conn.recv()
                      match msg.kind {
                        Text => {
                          let text = msg.read_all().text()
                          transport.dispatch_ws_frame(
                            @utf8.encode(text),
                            target_key,
                          )
                        }
                        Binary => {
                          let bytes = msg.read_all().binary()
                          transport.dispatch_ws_frame(bytes, target_key)
                        }
                      }
                    }
                  } catch {
                    _ => ()
                  }
                })
                if !wrapper.broken.val {
                  wrapper.reader = Some(task)
                }
              }
              _ => ()
            }
          }
        }

        while wrapper.sending.val && !self.closed {
          @async.sleep(5)
        }

        if self.closed {
          return false
        }
        if wrapper.broken.val {
          self.close_connection(target_key, wrapper)
          continue
        }
        wrapper.sending.val = true
        defer {
          wrapper.sending.val = false
        }
        try {
          wrapper.conn.send_binary(frame_bytes)
          wrapper.sending.val = false
          return true
        } catch {
          _ => {
            wrapper.sending.val = false
            self.close_connection(target_key, wrapper)
          }
        }
      }
      None => if i == 1 { return false }
    }
  }
  false
}

///|
impl Transport for WebSocketTransport with fn set_raw_data_handler(
  self,
  handler,
) -> Unit {
  if !self.closed {
    self.raw_data_handler = Some(handler)
  }
}

///|
impl Transport for WebSocketTransport with fn listen(
  self,
  root,
  handler,
  on_disconnect,
) {
  if self.closed {
    return
  }
  self.handler = Some(handler)
  self.on_disconnect = Some(on_disconnect)
  self.root = Some(root)
  defer {
    self.closed = true
    for (target, wrapper) in self.connections.to_array() {
      self.close_connection(target, wrapper)
    }
    self.handler = None
    self.raw_data_handler = None
    self.on_disconnect = None
    self.root = None
  }
  self.server.run_forever(async fn(request, _resp, conn) {
    let client_addr = conn.client_addr().to_string()
    try {
      let ws = @websocket.from_http_server(request, conn)
      let wrapper = WebSocketConnWrapper::{
        conn: ws,
        sending: { val: false, },
        broken: { val: false, },
        reader: None,
      }
      self.connections[client_addr] = wrapper
      self.reader_started[client_addr] = true
      defer {
        wrapper.reader = None
        ws.close()
        wrapper.broken.val = true
        self.forget_connection(client_addr, wrapper)
      }
      let task = root.spawn(() => {
        defer {
          wrapper.reader = None
        }
        try {
          for ;; {
            let msg = ws.recv()
            match msg.kind {
              Text => {
                let text = msg.read_all().text()
                self.dispatch_ws_frame(@utf8.encode(text), client_addr)
              }
              Binary => {
                let bytes = msg.read_all().binary()
                self.dispatch_ws_frame(bytes, client_addr)
              }
            }
          }
        } catch {
          _ => ()
        }
      })
      wrapper.reader = Some(task)
      defer task.cancel()
      task.wait()
    } catch {
      _ => ()
    }
  })
}

///|
impl Transport for WebSocketTransport with fn local_addr(self) {
  self.server.addr.to_string()
}

///|
impl Transport for WebSocketTransport with fn protocol(_self) {
  "ws"
}

///|
impl Transport for WebSocketTransport with fn protocol_type(_self) {
  Ws
}

///|
impl Transport for WebSocketTransport with fn local_address(self) {
  let addr_str = "ws://" + self.server.addr.to_string()
  Address::parse(addr_str) catch {
    _ => abort("Invalid local address: " + addr_str)
  }
}
