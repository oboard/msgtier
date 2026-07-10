///|
struct UdpTransport {
  server : @socket.UdpServer
}

///|
async fn UdpTransport::UdpTransport(addr_str : String) -> UdpTransport {
  let addr = @socket.Addr::parse(addr_str) catch {
    e => abort("Invalid address: " + e.to_string())
  }
  { server: @socket.UdpServer(addr) }
}

///|
impl Transport for UdpTransport with fn send(self, target, data) {
  let target = target.strip_prefix("udp://").unwrap_or(target).to_owned()
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
impl Transport for UdpTransport with fn listen(
  self,
  _root,
  handler,
  _on_disconnect,
) {
  let buf = FixedArray::make(65536, b'0')
  for ;; {
    try {
      let (n, sender) = self.server.recvfrom(buf)
      let bytes = buf.unsafe_reinterpret_as_bytes()[0:n].to_owned()
      handler(bytes, sender.to_string())
    } catch {
      _ => ()
    }
  }
}

///|
impl Transport for UdpTransport with fn local_addr(self) {
  self.server.addr.to_string()
}

///|
impl Transport for UdpTransport with fn protocol(_self) {
  "udp"
}

///|
impl Transport for UdpTransport with fn protocol_type(_self) {
  Udp
}

///|
impl Transport for UdpTransport with fn local_address(self) {
  let addr_str = "udp://" + self.server.addr.to_string()
  Address::parse(addr_str) catch {
    _ => abort("Invalid local address: " + addr_str)
  }
}
