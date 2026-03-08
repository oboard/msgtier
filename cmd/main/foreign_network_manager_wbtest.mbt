///|
test "foreign_network_manager" {
  let mgr = ForeignNetworkManager::new(relay_bps_limit=1000)
  inspect(mgr.relay_bps_limit, content="1000")
  let payload = b"\x01\x02\x03"
  let packet : ForeignNetworkPacket = {
    target_network: "net1",
    target_peer_id: "peer1",
    payload,
  }
  inspect(packet.target_network, content="net1")
  inspect(packet.target_peer_id, content="peer1")
  inspect(packet.target_network, content="net1")
  inspect(packet.target_peer_id, content="peer1")
  inspect(packet.payload, content="b\"\\x01\\x02\\x03\"")
}
