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
async fn UdpTransport::send(
  self : UdpTransport,
  target : String,
  data : Bytes,
) -> Bool {
  try {
    let target_addr = @socket.Addr::parse(target)
    self.server.sendto(data, target_addr)
    true
  } catch {
    _ => false
  }
}

///|
async fn UdpTransport::listen(
  self : UdpTransport,
  handler : (Bytes, String) -> Unit,
) -> Unit {
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
impl Transport for UdpTransport with send(self, target, data) {
  self.send(target, data)
}

///|
impl Transport for UdpTransport with listen(self, handler) {
  self.listen(handler)
}

///|
impl Transport for UdpTransport with local_addr(self) {
  self.server.addr().to_string()
}

///|
impl Transport for UdpTransport with protocol(_self) {
  "udp"
}
