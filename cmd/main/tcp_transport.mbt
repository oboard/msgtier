///|
suberror TransportError {
  TransportError(String)
} derive(Debug)

///|
struct TcpTransportState {
  max_frame_size : Int
}

///|
let tcp_transport_state : TcpTransportState = {
  max_frame_size: 64 * 1024 * 1024,
}

///|
struct TcpConnection {
  socket : @socket.Tcp
  sending : Ref[Bool]
}

///|
struct TcpTransport {
  server : @socket.TcpServer
  connections : Map[String, TcpConnection]
  mut handler : ((Bytes, String) -> Unit)?
  mut raw_data_handler : ((String, Int, Bytes) -> Unit)?
  mut on_disconnect : ((String) -> Unit)?
  mut root : @async.TaskGroup[Unit]?
  reader_started : Map[String, Bool]
}

///|
async fn TcpTransport::TcpTransport(addr_str : String) -> TcpTransport {
  let addr = @socket.Addr::parse(addr_str) catch {
    e => abort("Invalid address: " + e.to_string())
  }
  {
    server: @socket.TcpServer(addr, reuse_addr=true),
    connections: {},
    handler: None,
    raw_data_handler: None,
    on_disconnect: None,
    root: None,
    reader_started: {},
  }
}

///|
// Dispatch a raw port-forward frame to the registered raw_data_handler.
// payload: [connection_id UTF-8]['\x00'][4-byte seq BE][data]
fn TcpTransport::dispatch_raw_frame(
  self : TcpTransport,
  payload : Bytes,
) -> Unit {
  match self.raw_data_handler {
    None => ()
    Some(raw_handler) => {
      let mut sep = -1
      for i = 0; i < payload.length(); i = i + 1 {
        if payload[i] == b'\x00' {
          sep = i
          break
        }
      }
      if sep < 0 || sep + 5 > payload.length() {
        return
      }
      let connection_id = try {
        @utf8.decode(slice_bytes(payload, 0, sep))
      } catch {
        _ => return
      }
      let seq = (payload[sep + 1].to_int() << 24) |
        (payload[sep + 2].to_int() << 16) |
        (payload[sep + 3].to_int() << 8) |
        payload[sep + 4].to_int()
      // Reinterpret the tail of the already-allocated buffer as the data slice —
      // avoids a second 4MB allocation+copy compared to slice_bytes.
      let data = payload[sep + 5:]
      raw_handler(connection_id, seq, data.to_owned())
    }
  }
}

///|
// Read loop body: read one frame from the BufferedReader, dispatch to handler or raw_data_handler.
// Returns true to continue, false to break.
async fn TcpTransport::read_one_frame(
  self : TcpTransport,
  reader : BufferedReader,
  header_buf : FixedArray[Byte],
  sender_addr : String,
) -> Bool {
  reader.read_exact(header_buf, 4)
  let h0 = header_buf[0].to_int()
  let h1 = header_buf[1].to_int()
  let h2 = header_buf[2].to_int()
  let h3 = header_buf[3].to_int()
  let header_word = (h0 << 24) | (h1 << 16) | (h2 << 8) | h3
  let is_raw = (h0 & 0x80) != 0
  let len = if is_raw {
    header_word & 0x7FFFFFFF
  } else {
    header_word
  }
  if len <= 0 || len > tcp_transport_state.max_frame_size {
    return false
  }
  let data_buf = FixedArray::make(len, b'\x00')
  reader.read_exact(data_buf, len)
  let payload = data_buf.unsafe_reinterpret_as_bytes()
  if is_raw {
    self.dispatch_raw_frame(payload)
  } else {
    match self.handler {
      Some(handler) => handler(payload, sender_addr)
      None => ()
    }
  }
  true
}

///|
impl Transport for TcpTransport with fn send(self, target, data) {
  let target = target.strip_prefix("tcp://").unwrap_or(target).to_owned()

  // Framing: 4 bytes length header sent separately from data to avoid an extra copy
  let len = data.length()
  let header = FixedArray::make(4, b'\x00')
  header[0] = (len >> 24).to_byte()
  header[1] = (len >> 16).to_byte()
  header[2] = (len >> 8).to_byte()
  header[3] = len.to_byte()
  let header_bytes = header.unsafe_reinterpret_as_bytes()

  // Retry loop (max 2 attempts)
  for i = 0; i < 2; i = i + 1 {
    try {
      let mut conn_opt = match self.connections.get(target) {
        Some(wrapper) => Some(wrapper)
        None => None
      }
      let mut created = false
      if conn_opt is None {
        try {
          let target_addr = @socket.Addr::parse(target)
          let c = @socket.Tcp::connect(target_addr)
          let wrapper = TcpConnection::{ socket: c, sending: Ref(false) }
          self.connections[target] = wrapper
          conn_opt = Some(wrapper)
          created = true
        } catch {
          _ => ()
        }
      }
      guard conn_opt is Some({ socket: conn, sending }) else {
        if i == 1 {
          return false
        }
        continue
      }

      if created && self.reader_started.get(target) is None {
        match (self.root, self.on_disconnect) {
          (Some(root), Some(on_disconnect)) => {
            self.reader_started[target] = true
            let transport = self
            root.spawn_bg(async fn() {
              let reader = BufferedReader::new(conn)
              let header_buf = FixedArray::make(4, b'\x00')
              try {
                for ;; {
                  if !transport.read_one_frame(reader, header_buf, target) {
                    break
                  }
                }
              } catch {
                _ => ()
              }
              transport.connections.remove(target)
              transport.reader_started.remove(target)
              on_disconnect(target)
            })
          }
          _ => ()
        }
      }

      // Spinlock to prevent concurrent writes
      while sending.val {
        @async.sleep(1)
      }
      sending.val = true
      try {
        conn.write(header_bytes)
        conn.write(data)
        sending.val = false
        return true
      } catch {
        e => {
          sending.val = false
          raise e
        }
      }
    } catch {
      _ => {
        self.connections.remove(target)
        self.reader_started.remove(target)
        log_warn("TCP send failed for target \{target}: connection closed")
      }
    }
  }
  false
}

///|
impl Transport for TcpTransport with fn send_raw_port_forward(
  self,
  target,
  connection_id,
  seq,
  data,
) {
  let target = target.strip_prefix("tcp://").unwrap_or(target).to_owned()
  let id_bytes = @utf8.encode(connection_id)
  let id_len = id_bytes.length()
  // payload: [connection_id]['\x00'][4-byte seq BE][data]
  let payload_len = id_len + 1 + 4 + data.length()
  // 4-byte length header with raw_frame_flag (MSB=1)
  let header = FixedArray::make(4, b'\x00')
  header[0] = ((payload_len >> 24) | 0x80).to_byte()
  header[1] = (payload_len >> 16).to_byte()
  header[2] = (payload_len >> 8).to_byte()
  header[3] = payload_len.to_byte()
  let header_bytes = header.unsafe_reinterpret_as_bytes()
  // Build inline header: connection_id + '\x00' + 4-byte seq
  let inline_header = FixedArray::make(id_len + 1 + 4, b'\x00')
  inline_header.blit_from_bytes(0, id_bytes, 0, id_len)
  // byte [id_len] stays 0x00 (null separator)
  inline_header[id_len + 1] = (seq >> 24).to_byte()
  inline_header[id_len + 2] = (seq >> 16).to_byte()
  inline_header[id_len + 3] = (seq >> 8).to_byte()
  inline_header[id_len + 4] = seq.to_byte()
  let inline_bytes = inline_header.unsafe_reinterpret_as_bytes()

  // Retry loop (max 2 attempts)
  for i = 0; i < 2; i = i + 1 {
    try {
      let mut conn_opt = match self.connections.get(target) {
        Some(wrapper) => Some(wrapper)
        None => None
      }
      let mut created = false
      if conn_opt is None {
        try {
          let target_addr = @socket.Addr::parse(target)
          let c = @socket.Tcp::connect(target_addr)
          let wrapper = TcpConnection::{ socket: c, sending: Ref(false) }
          self.connections[target] = wrapper
          conn_opt = Some(wrapper)
          created = true
        } catch {
          _ => ()
        }
      }
      guard conn_opt is Some({ socket: conn, sending }) else {
        if i == 1 {
          return false
        }
        continue
      }

      if created && self.reader_started.get(target) is None {
        match (self.root, self.on_disconnect) {
          (Some(root), Some(on_disconnect)) => {
            self.reader_started[target] = true
            let transport = self
            root.spawn_bg(async fn() {
              let reader = BufferedReader::new(conn)
              let header_buf = FixedArray::make(4, b'\x00')
              try {
                for ;; {
                  if !transport.read_one_frame(reader, header_buf, target) {
                    break
                  }
                }
              } catch {
                _ => ()
              }
              transport.connections.remove(target)
              transport.reader_started.remove(target)
              on_disconnect(target)
            })
          }
          _ => ()
        }
      }

      while sending.val {
        @async.sleep(1)
      }
      sending.val = true
      try {
        conn.write(header_bytes)
        conn.write(inline_bytes)
        conn.write(data)
        sending.val = false
        return true
      } catch {
        e => {
          sending.val = false
          raise e
        }
      }
    } catch {
      _ => {
        self.connections.remove(target)
        self.reader_started.remove(target)
        log_warn("TCP raw send failed for target \{target}")
      }
    }
  }
  false
}

///|
impl Transport for TcpTransport with fn set_raw_data_handler(self, handler) -> Unit {
  self.raw_data_handler = Some(handler)
}

///|
impl Transport for TcpTransport with fn listen(
  self,
  root,
  handler,
  on_disconnect,
) {
  self.handler = Some(handler)
  self.on_disconnect = Some(on_disconnect)
  self.root = Some(root)
  self.server.run_forever(async fn(conn, remote_addr) {
    let remote_addr_str = remote_addr.to_string()
    self.connections[remote_addr_str] = TcpConnection::{
      socket: conn,
      sending: Ref(false),
    }
    self.reader_started[remote_addr_str] = true
    let reader = BufferedReader::new(conn)
    let header_buf = FixedArray::make(4, b'\x00')
    try {
      for ;; {
        if !self.read_one_frame(reader, header_buf, remote_addr_str) {
          break
        }
      }
    } catch {
      _ => ()
    }
    self.connections.remove(remote_addr_str)
    self.reader_started.remove(remote_addr_str)
    on_disconnect(remote_addr_str)
  })
}

///|
impl Transport for TcpTransport with fn local_addr(self) {
  self.server.addr.to_string()
}

///|
impl Transport for TcpTransport with fn protocol(_self) {
  "tcp"
}

///|
impl Transport for TcpTransport with fn protocol_type(_self) {
  Tcp
}

///|
impl Transport for TcpTransport with fn local_address(self) {
  let addr_str = "tcp://" + self.server.addr.to_string()
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
    if self.offset >= self.buffer.length() {
      match self.conn.read_some() {
        Some(chunk) => {
          if chunk.length() == 0 {
            raise TransportError::TransportError("Connection closed by peer")
          }
          self.buffer = chunk
          self.offset = 0
        }
        None => raise TransportError::TransportError("Connection closed")
      }
    }
    let available = self.buffer.length() - self.offset
    let needed = count - buf_offset
    let to_copy = if available < needed { available } else { needed }
    buf.blit_from_bytes(buf_offset, self.buffer, self.offset, to_copy)
    self.offset = self.offset + to_copy
    buf_offset = buf_offset + to_copy
  }
}
