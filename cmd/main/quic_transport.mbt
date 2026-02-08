///|
pub struct QuicTransport {
  endpoint : @quic.Endpoint
}

///|
fn QuicTransport::new(addr_str : String) -> QuicTransport raise {
  let endpoint = @quic.Endpoint::new(addr_str)
  { endpoint, }
}

///|
impl Transport for QuicTransport with send(self, target, data) {
  let target = target.strip_prefix("quic://").unwrap_or(target).to_string()
  let conn = self.endpoint.connect(target)
  let stream = conn.open_stream()
  self.endpoint.send_stream_data(conn, stream.id, data)
  true
}

///|
impl Transport for QuicTransport with listen(
  self,
  _root,
  handler,
  _on_disconnect,
) {
  self.endpoint.listen(fn(conn, stream) {
    handler(stream.incoming_data, conn.addr)
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
