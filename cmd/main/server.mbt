///|
async fn listen_udp(root : @async.TaskGroup[Unit], addr : @socket.Addr) -> Unit {
  let server = @socket.UdpServer::new(addr)
  defer server.close()
  for {
    let buf = FixedArray::make(1024, b'0')
    let (n, addr) = server.recvfrom(buf)
    root.spawn_bg(fn() {
      let buf = buf.unsafe_reinterpret_as_bytes()
      server.sendto(buf[0:n].to_bytes(), addr)
    })
  }
}
