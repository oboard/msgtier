///|
test "pk_persistence_fallback" {
  // 0. Initialize global config (needed for log_debug)
  global_config.val = Some({
    id: "test_node_local_pk_test",
    secret: "test_secret",
    peers: [],
    listeners: [],
    scripts: None,
    web_api: None,
    metadata: None,
    log: None,
    port: None,
  })

  // 1. Initialize local keypair (needed for ECDH)
  init_keypair("test_node_local_pk_test")

  // 2. Generate remote peer keypair
  let remote_priv = @x25519.generate_private_key()
  let remote_pub = @x25519.compute_public_key(remote_priv)
  let peer_id = "test_peer_remote_pk_test"

  // 3. Create PeerNode with remote public key
  let peer_node = PeerNode::new(
    id=peer_id,
    version="1.0.0",
    public_key=remote_pub,
    addresses=["tcp://127.0.0.1:9999"],
    metadata={},
  )

  // 4. Add to PeerManager
  update_global_peer_manager(fn(m) { m.add_peer(peer_node) })

  // 5. Get shared secret - should trigger fallback to PeerManager
  let secret = get_shared_secret(peer_id)

  // 6. Verify
  match secret {
    Some(s) => {
      // Verify it is not empty
      inspect(s.length() > 0, content="true")

      // Verify it is correct
      let my_priv = get_private_key()
      let expected = @x25519.compute_shared_secret(my_priv, remote_pub)
      assert_eq(s, expected)

      // Verify it is now stored in global_shared_secrets (implicit via second call returning same)
      let secret2 = get_shared_secret(peer_id)
      assert_eq(secret2, Some(s))
    }
    None => fail("Shared secret should be computed via fallback")
  }
}
