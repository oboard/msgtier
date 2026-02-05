///|
suberror TransportError {
  TransportError(String)
} derive(Show)

///|
struct TcpTransport {
  server : @socket.TcpServer
  connections : Map[String, @socket.Tcp]
}

///|
pub fn TcpTransport::new(addr_str : String) -> TcpTransport raise {
  let addr = @socket.Addr::parse(addr_str) catch {
    e => abort("Invalid address: " + e.to_string())
  }
  { server: @socket.TcpServer::new(addr), connections: {} }
}

///|
async fn TcpTransport::send(
  self : TcpTransport,
  target : String,
  data : Bytes,
) -> Bool {
  let conn = match self.connections.get(target) {
    Some(c) => c
    None =>
      try {
        let target_addr = @socket.Addr::parse(target)
        let c = @socket.Tcp::connect(target_addr)
        self.connections[target] = c
        c
      } catch {
        _ => return false
      }
  }

  // Framing: 4 bytes length + data
  let len = data.length()
  let header : Bytes = [
    (len >> 24).to_byte(),
    (len >> 16).to_byte(),
    (len >> 8).to_byte(),
    len.to_byte(),
  ]
  try {
    conn.write(header)
    conn.write(data)
    true
  } catch {
    _ => {
      // Retry once with new connection
      self.connections.remove(target)
      try {
        let target_addr = @socket.Addr::parse(target)
        let c = @socket.Tcp::connect(target_addr)
        self.connections[target] = c
        c.write(header)
        c.write(data)
        true
      } catch {
        _ => false
      }
    }
  }
}

///|
async fn TcpTransport::listen(
  self : TcpTransport,
  handler : (Bytes, String) -> Unit,
) -> Unit {
  self.server.run_forever(fn(conn, remote_addr) {
    try {
      let reader = BufferedReader::new(conn)
      // TCP Connection Handler
      // Read loop with framing
      for {
        // Read 4 bytes length
        let header_buf = FixedArray::make(4, b'\x00')
        reader.read_exact(header_buf, 4)
        let header_bytes = header_buf.unsafe_reinterpret_as_bytes()
        let len = (header_bytes[0].to_int() << 24) |
          (header_bytes[1].to_int() << 16) |
          (header_bytes[2].to_int() << 8) |
          header_bytes[3].to_int()
        if len > 10 * 1024 * 1024 { // 10MB limit sanity check
          break
        }
        let data_buf = FixedArray::make(len, b'\x00')
        reader.read_exact(data_buf, len)
        // Convert FixedArray to Bytes (immutable copy)
        let data_bytes = data_buf.unsafe_reinterpret_as_bytes()
        handler(data_bytes, remote_addr.to_string())
      }
    } catch {
      _ => () // Connection closed or error
    }
  })
}

///|
impl Transport for TcpTransport with send(self, target, data) {
  self.send(target, data)
}

///|
impl Transport for TcpTransport with listen(self, handler) {
  self.listen(handler)
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
) -> Unit raise {
  let mut buf_offset = 0
  while buf_offset < count {
    // If current buffer is exhausted, read more
    if self.offset >= self.buffer.length() {
      match self.conn.read_some() {
        Some(chunk) => {
          if chunk.length() == 0 {
            continue
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
