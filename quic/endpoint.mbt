///|
pub struct Endpoint {
  socket : @socket.UdpServer
  connections : Map[String, Connection] // Key is Connection ID
}

///|
pub fn Endpoint::new(addr_str : String) -> Endpoint raise {
  let addr = @socket.Addr::parse(addr_str) catch {
    e => abort("Invalid address: " + e.to_string())
  }
  let socket = @socket.UdpServer::new(addr)
  { socket, connections: {} }
}

///|
pub async fn Endpoint::listen(
  self : Endpoint,
  handler : (Connection, Stream) -> Unit,
) -> Unit {
  let buf = FixedArray::make(65536, b'\x00')
  for {
    try {
      let (n, sender_addr) = self.socket.recvfrom(buf)
      let bytes = slice(Bytes::from_array(buf), 0, n)
      self.handle_packet(bytes, sender_addr.to_string(), handler)
    } catch {
      _ => () // Ignore errors for now
    }
  }
}

///|
fn Endpoint::handle_packet(
  self : Endpoint,
  data : Bytes,
  sender_addr : String,
  handler : (Connection, Stream) -> Unit,
) -> Unit {
  match parse_header(data) {
    Some(header) => {
      // Logic to find or create connection
      // For now, assume simplified connection ID mapping or create new for any
      // In real QUIC, use DCID.
      // We need to extract DCID from header.
      // But header.dest_cid is BytesView/Bytes.
      // Let's assume we use sender_addr as key for simplicity if CID not fully managed yet.
      // Or just map a single connection for the test.

      let conn = match self.connections.get(sender_addr) {
        Some(c) => c
        None => {
          let c = Connection::new(sender_addr, "new_cid", true)
          self.connections[sender_addr] = c
          c
        }
      }

      // Parse Payload
      let header_size = match header.version {
        Some(_) => {
          // 1 (flags) + 4 (ver) + 1 (dcid len) + dcid len + 1 (scid len) + scid len
          let dcid_len = header.dest_cid.length()
          let scid_len = match header.src_cid {
            Some(s) => s.length()
            None => 0
          }
          1 + 4 + 1 + dcid_len + 1 + scid_len
        }
        None => 1
      }
      let frames = if data.length() > header_size {
        let payload = slice(data, header_size, data.length() - header_size)
        parse_frames(payload)
      } else {
        []
      }
      for frame in frames {
        conn.handle_frame(frame)
        match frame {
          Stream(s) =>
            match conn.streams.get(s.stream_id) {
              Some(stream) => handler(conn, stream)
              None => ()
            }
          _ => ()
        }
      }
    }
    None => ()
  }
}

///|
pub fn Endpoint::connect(self : Endpoint, addr : String) -> Connection {
  match self.connections.get(addr) {
    Some(conn) => conn
    None => {
      let conn_id = "random_cid" // Should generate random CID
      let conn = Connection::new(addr, conn_id, false)
      self.connections[addr] = conn
      conn
    }
  }
}

///|
pub async fn Endpoint::send_stream_data(
  self : Endpoint,
  conn : Connection,
  stream_id : Int64,
  data : Bytes,
) -> Unit {
  let frame = Frame::Stream({ stream_id, offset: 0L, fin: true, data })
  let encoded_frame = encode_frame(frame)
  let header : Header = {
    first_byte: b'\x40',
    version: None,
    dest_cid: @utf8.encode(conn.conn_id)[:],
    src_cid: None,
    packet_number: conn.next_packet_number(),
    payload_length: None,
  }
  let packet = encode_packet(header, encoded_frame)
  let target_addr = @socket.Addr::parse(conn.addr) catch { _ => return }
  try {
    self.socket.sendto(packet, target_addr)
    ()
  } catch {
    _ => ()
  }
}
