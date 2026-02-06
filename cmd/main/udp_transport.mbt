///|
struct UdpTransport {
  server : @socket.UdpServer
}

///|
pub fn UdpTransport::new(addr_str : String) -> UdpTransport raise {
  let addr = @socket.Addr::parse(addr_str) catch {
    e => abort("Invalid address: " + e.to_string())
  }
  { server: @socket.UdpServer::new(addr) }
}

///|
impl Transport for UdpTransport with send(self, target, data) {
  try {
    let target_clean = if target.has_prefix("udp://") {
      target[6:].to_string()
    } else {
      target
    }
    let target_addr = @socket.Addr::parse(target_clean)
    self.server.sendto(data, target_addr)
    true
  } catch {
    _ => false
  }
}

///|
impl Transport for UdpTransport with listen(
  self,
  _root,
  handler,
  _on_disconnect,
) {
  let buf = FixedArray::make(65536, b'0')
  for {
    try {
      let (n, sender) = self.server.recvfrom(buf)
      let bytes = buf.unsafe_reinterpret_as_bytes()[0:n].to_bytes()
      handler(bytes, sender.to_string())
    } catch {
      _ => ()
    }
  }
}

///|
impl Transport for UdpTransport with local_addr(self) {
  "udp://" + self.server.addr().to_string()
}

///|
impl Transport for UdpTransport with protocol(_self) {
  "udp"
}
