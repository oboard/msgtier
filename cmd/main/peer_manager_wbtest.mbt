///|
test "update_peer_public_key_overwrite" {
  let pm = PeerManager::new()
  let pk1 = b"\x01\x02\x03"
  let pk2 = b"\x04\x05\x06"
  let peer = PeerNode::new(
    id="peer1",
    version="1",
    public_key=pk1,
    addresses=[],
    metadata={},
  )
  let pm2 = pm.add_peer(peer)

  // Verify initial key
  match pm2.get_peer("peer1") {
    Some(p) => assert_eq(p.public_key, pk1)
    None => fail("Peer not found")
  }

  // Update with new key
  let pm3 = pm2.update_peer_public_key("peer1", pk2)

  // Verify updated key
  match pm3.get_peer("peer1") {
    Some(p) => assert_eq(p.public_key, pk2)
    None => fail("Peer not found after update")
  }
}
