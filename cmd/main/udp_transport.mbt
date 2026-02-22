///|
struct UdpTransport {
  server : @socket.UdpServer
}

///|
fn UdpTransport::new(addr_str : String) -> UdpTransport raise {
  let addr = @socket.Addr::parse(addr_str) catch {
    e => abort("Invalid address: " + e.to_string())
  }
  { server: @socket.UdpServer::new(addr) }
}

///|
impl Transport for UdpTransport with send(self, target, data) {
  let target = target.strip_prefix("udp://").unwrap_or(target).to_string()
  let target_addr = @socket.Addr::parse(target) catch { _ => return false }
  for i = 0; i < 3; i = i + 1 {
    try {
      self.server.sendto(data, target_addr)
      return true
    } catch {
      _ => if i < 2 { @async.sleep(5) }
    }
  }
  false
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
  self.server.addr().to_string()
}

///|
impl Transport for UdpTransport with protocol(_self) {
  "udp"
}

///|
impl Transport for UdpTransport with protocol_type(_self) {
  Udp
}

///|
impl Transport for UdpTransport with local_address(self) {
  let addr_str = "udp://" + self.server.addr().to_string()
  Address::parse(addr_str) catch {
    _ => abort("Invalid local address: " + addr_str)
  }
}
