///|
pub struct QuicTransport {
  endpoint : @quic.Endpoint
  connections : Map[String, @quic.Connection]
}

///|
fn QuicTransport::new(addr_str : String) -> QuicTransport raise {
  let endpoint = @quic.Endpoint::new(addr_str)
  { endpoint, connections: {} }
}

///|
impl Transport for QuicTransport with send(self, target, data) {
  let target = target.strip_prefix("quic://").unwrap_or(target).to_string()
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
impl Transport for QuicTransport with listen(
  self,
  _root,
  handler,
  _on_disconnect,
) {
  self.endpoint.listen(fn(conn, stream) {
    let remote_addr = conn.addr
    self.connections[remote_addr] = conn
    handler(stream.incoming_data, remote_addr)
  })
}

///|
impl Transport for QuicTransport with local_addr(self) {
  self.endpoint.addr().to_string()
}

///|
impl Transport for QuicTransport with protocol(_self) {
  "quic"
}

///|
impl Transport for QuicTransport with protocol_type(_self) {
  Quic
}

///|
impl Transport for QuicTransport with local_address(self) {
  let addr_str = "quic://" + self.endpoint.addr().to_string()
  Address::parse(addr_str) catch {
    _ => abort("Invalid local address: " + addr_str)
  }
}
