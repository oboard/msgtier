///|
test "foreign_network_manager" {
  let mgr = ForeignNetworkManager::new(relay_bps_limit=1000)
  inspect(mgr.relay_bps_limit, content="1000")
  let payload = b"\x01\x02\x03"
  let packet = mgr.wrap_packet("net1", "peer1", payload)
  inspect(packet.target_network, content="net1")
  inspect(packet.target_peer_id, content="peer1")
  let (net, peer, data) = mgr.unwrap_packet(packet)
  inspect(net, content="net1")
  inspect(peer, content="peer1")
  inspect(data, content="b\"\\x01\\x02\\x03\"")
}
