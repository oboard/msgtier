///|
pub struct QuicTransport {
  endpoint : @quic.Endpoint
  connections : Map[String, @quic.Connection]
  mut raw_data_handler : ((String, Int, Bytes) -> Unit)?
}

///|
async fn QuicTransport::QuicTransport(addr_str : String) -> QuicTransport {
  let endpoint = @quic.Endpoint::new(addr_str)
  { endpoint, connections: {}, raw_data_handler: None }
}

///|
// Dispatch a received QUIC stream payload (same tag scheme as WS).
fn QuicTransport::dispatch_quic_frame(
  self : QuicTransport,
  bytes : Bytes,
  remote_addr : String,
  handler : (Bytes, String) -> Unit,
) -> Unit {
  if bytes.length() == 0 {
    return
  }
  if bytes[0] == b'\x01' {
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
    handler(bytes, remote_addr)
  }
}

///|
impl Transport for QuicTransport with fn send(self, target, data) {
  let target = target.strip_prefix("quic://").unwrap_or(target).to_owned()
  try {
    let conn = match self.connections.get(target) {
      Some(c) => c
      None => {
        let c = self.endpoint.connect(target)
        self.connections[target] = c
        c
      }
    }
    let stream = conn.open_stream()
    self.connections[target] = conn
    self.endpoint.send_stream_data(conn, stream.id, data)
    true
  } catch {
    _ => {
      self.connections.remove(target)
      false
    }
  }
}

///|
impl Transport for QuicTransport with fn send_raw_port_forward(
  self,
  target,
  connection_id,
  seq,
  data,
) {
  let target = target.strip_prefix("quic://").unwrap_or(target).to_owned()
  let id_bytes = @utf8.encode(connection_id)
  let id_len = id_bytes.length()
  let frame_len = 1 + id_len + 1 + 4 + data.length()
  let frame = FixedArray::make(frame_len, b'\x00')
  frame[0] = b'\x01'
  frame.blit_from_bytes(1, id_bytes, 0, id_len)
  frame[1 + id_len + 1] = (seq >> 24).to_byte()
  frame[1 + id_len + 2] = (seq >> 16).to_byte()
  frame[1 + id_len + 3] = (seq >> 8).to_byte()
  frame[1 + id_len + 4] = seq.to_byte()
  frame.blit_from_bytes(1 + id_len + 5, data, 0, data.length())
  let frame_bytes = frame.unsafe_reinterpret_as_bytes()
  try {
    let conn = match self.connections.get(target) {
      Some(c) => c
      None => {
        let c = self.endpoint.connect(target)
        self.connections[target] = c
        c
      }
    }
    let stream = conn.open_stream()
    self.connections[target] = conn
    self.endpoint.send_stream_data(conn, stream.id, frame_bytes)
    true
  } catch {
    _ => {
      self.connections.remove(target)
      false
    }
  }
}

///|
impl Transport for QuicTransport with fn set_raw_data_handler(self, handler) -> Unit {
  self.raw_data_handler = Some(handler)
}

///|
impl Transport for QuicTransport with fn listen(
  self,
  _root,
  handler,
  _on_disconnect,
) {
  let transport = self
  self.endpoint.listen(fn(conn, stream) {
    let remote_addr = conn.addr
    transport.connections[remote_addr] = conn
    transport.dispatch_quic_frame(stream.incoming_data, remote_addr, handler)
  })
}

///|
impl Transport for QuicTransport with fn local_addr(self) {
  self.endpoint.addr().to_string()
}

///|
impl Transport for QuicTransport with fn protocol(_self) {
  "quic"
}

///|
impl Transport for QuicTransport with fn protocol_type(_self) {
  Quic
}

///|
impl Transport for QuicTransport with fn local_address(self) {
  let addr_str = "quic://" + self.endpoint.addr().to_string()
  Address::parse(addr_str) catch {
    _ => abort("Invalid local address: " + addr_str)
  }
}
