///|
suberror TransportError {
  TransportError(String)
} derive(Show)

///|
struct TcpTransport {
  server : @socket.TcpServer
  connections : Map[String, @socket.Tcp]
  mut handler : ((Bytes, String) -> Unit)?
  mut on_disconnect : ((String) -> Unit)?
  mut root : @async.TaskGroup[Unit]?
  reader_started : Map[String, Bool]
}

///|
fn TcpTransport::new(addr_str : String) -> TcpTransport raise {
  let addr = @socket.Addr::parse(addr_str) catch {
    e => abort("Invalid address: " + e.to_string())
  }
  {
    server: @socket.TcpServer::new(addr, reuse_addr=true),
    connections: {},
    handler: None,
    on_disconnect: None,
    root: None,
    reader_started: {},
  }
}

///|
impl Transport for TcpTransport with send(self, target, data) {
  let target = target.strip_prefix("tcp://").unwrap_or(target).to_string()

  // Framing: 4 bytes length + data
  let len = data.length()
  let header : Bytes = [
    (len >> 24).to_byte(),
    (len >> 16).to_byte(),
    (len >> 8).to_byte(),
    len.to_byte(),
  ]

  // Retry loop (max 2 attempts)
  for i = 0; i < 2; i = i + 1 {
    try {
      // Get or create connection
      // We use a mutable variable to avoid complex match/async interaction issues
      let mut conn_opt = self.connections.get(target)
      let mut created = false
      if conn_opt is None {
        try {
          let target_addr = @socket.Addr::parse(target)
          let c = @socket.Tcp::connect(target_addr)
          self.connections[target] = c
          conn_opt = Some(c)
          created = true
        } catch {
          _ => () // Will be handled by outer try/catch or loop
        }
      }
      match conn_opt {
        Some(conn) => {
          if created {
            if self.reader_started.get(target) is None {
              match (self.root, self.handler, self.on_disconnect) {
                (Some(root), Some(handler), Some(on_disconnect)) => {
                  self.reader_started[target] = true
                  root.spawn_bg(fn() {
                    let reader = BufferedReader::new(conn)
                    try {
                      for {
                        let header_buf = FixedArray::make(4, b'\x00')
                        reader.read_exact(header_buf, 4)
                        let header_bytes = header_buf.unsafe_reinterpret_as_bytes()
                        let len = (header_bytes[0].to_int() << 24) |
                          (header_bytes[1].to_int() << 16) |
                          (header_bytes[2].to_int() << 8) |
                          header_bytes[3].to_int()
                        if len > 10 * 1024 * 1024 {
                          break
                        }
                        let data_buf = FixedArray::make(len, b'\x00')
                        reader.read_exact(data_buf, len)
                        let data_bytes = data_buf.unsafe_reinterpret_as_bytes()
                        handler(data_bytes, target)
                      }
                    } catch {
                      _ => {
                        self.connections.remove(target)
                        self.reader_started.remove(target)
                        on_disconnect(target)
                      }
                    }
                  })
                }
                _ => ()
              }
            }
          }
          // Combine header and data to ensure atomic write
          // This prevents interleaving of header/data when multiple threads share the connection
          let full_packet = header + data
          conn.write(full_packet)
          return true
        }
        None =>
          // Connection creation failed
          if i == 1 {
            return false
          }
      }
    } catch {
      _ => { // Connection failed or write failed
        self.connections.remove(target)
        self.reader_started.remove(target)
        log_warn("TCP send failed for target \{target}: connection closed")
      }
    }
  }
  false
}

///|
impl Transport for TcpTransport with listen(self, root, handler, on_disconnect) {
  self.handler = Some(handler)
  self.on_disconnect = Some(on_disconnect)
  self.root = Some(root)
  self.server.run_forever(fn(conn, remote_addr) {
    let remote_addr_str = remote_addr.to_string()
    self.connections[remote_addr_str] = conn
    self.reader_started[remote_addr_str] = true
    let reader = BufferedReader::new(conn)
    try {
      // TCP Connection Handler - Read loop with framing
      for {
        // Read 4 bytes length header
        let header_buf = FixedArray::make(4, b'\x00')
        reader.read_exact(header_buf, 4)
        let header_bytes = header_buf.unsafe_reinterpret_as_bytes()
        let len = (header_bytes[0].to_int() << 24) |
          (header_bytes[1].to_int() << 16) |
          (header_bytes[2].to_int() << 8) |
          header_bytes[3].to_int()

        // Sanity check: 10MB limit
        if len > 10 * 1024 * 1024 {
          break
        }

        // Read message data
        let data_buf = FixedArray::make(len, b'\x00')
        reader.read_exact(data_buf, len)
        let data_bytes = data_buf.unsafe_reinterpret_as_bytes()
        handler(data_bytes, remote_addr_str)
      }
    } catch {
      _ => {
        self.connections.remove(remote_addr_str)
        self.reader_started.remove(remote_addr_str)
        on_disconnect(remote_addr_str)
      }
    }
  })
}

///|
impl Transport for TcpTransport with local_addr(self) {
  self.server.addr().to_string()
}

///|
impl Transport for TcpTransport with protocol(_self) {
  "tcp"
}

///|
impl Transport for TcpTransport with protocol_type(_self) {
  Tcp
}

///|
impl Transport for TcpTransport with local_address(self) {
  let addr_str = "tcp://" + self.server.addr().to_string()
  Address::parse(addr_str) catch {
    _ => abort("Invalid local address: " + addr_str)
  }
}

///|
struct BufferedReader {
  conn : @socket.Tcp
  mut buffer : Bytes
  mut offset : Int
}

///|
fn BufferedReader::new(conn : @socket.Tcp) -> BufferedReader {
  { conn, buffer: Bytes::make(0, b'\x00'), offset: 0 }
}

///|
async fn BufferedReader::read_exact(
  self : BufferedReader,
  buf : FixedArray[Byte],
  count : Int,
) -> Unit {
  let mut buf_offset = 0
  while buf_offset < count {
    // If current buffer is exhausted, read more
    if self.offset >= self.buffer.length() {
      match self.conn.read_some() {
        Some(chunk) => {
          if chunk.length() == 0 {
            // Connection closed by peer
            raise TransportError::TransportError("Connection closed by peer")
          }
          self.buffer = chunk
          self.offset = 0
        }
        None => raise TransportError::TransportError("Connection closed")
      }
    }

    // Copy from internal buffer to output buffer
    let available = self.buffer.length() - self.offset
    let needed = count - buf_offset
    let to_copy = if available < needed { available } else { needed }
    for i = 0; i < to_copy; i = i + 1 {
      buf[buf_offset + i] = self.buffer[self.offset + i]
    }
    self.offset = self.offset + to_copy
    buf_offset = buf_offset + to_copy
  }
}
