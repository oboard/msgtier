///|
// test "get_public_key returns None when keypair not initialized" {
//   inspect(get_public_key(), content="None")
// }

///|
// test "get_private_key returns None when keypair not initialized" {
//   inspect(get_private_key(), content="None")
// }

///|
test "init_keypair initializes both keys" {
  init_keypair("test_secret")
  let pub_key = get_public_key()
  let priv_key = get_private_key()
  inspect(pub_key.length() == 32, content="true")
  inspect(priv_key.length() == 32, content="true")
}

///|
test "get_shared_secret returns None for unknown peer" {
  let result = get_shared_secret("nonexistent")
  inspect(result, content="None")
}

///|
test "decrypt_from_peer returns None for unknown peer" {
  let encrypted : Bytes = b"encrypted"
  let result = decrypt_from_peer("unknown", encrypted)
  inspect(result, content="None")
}

///|
test "hash_secret produces consistent hash for same secret" {
  let secret = "network_secret_123"
  let hash1 = hash_secret(secret)
  let hash2 = hash_secret(secret)
  inspect(hash1 == hash2, content="true")
}

///|
test "hash_secret produces different hashes for different secrets" {
  let hash1 = hash_secret("secret_a")
  let hash2 = hash_secret("secret_b")
  inspect(hash1 == hash2, content="false")
}

///|
test "hash_secret produces 64 character hex string" {
  let hash = hash_secret("any_secret")
  inspect(hash.length(), content="64")
  // Should be valid hex characters
  for c in hash {
    let is_hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
    inspect(is_hex, content="true")
  }
}

///|
test "hash_secret handles short secrets by padding" {
  let short_hash = hash_secret("short")
  let long_hash = hash_secret("short_with_more_data_here_to_make_it_longer")
  // Both should produce valid 64-char hex strings
  inspect(short_hash.length(), content="64")
  inspect(long_hash.length(), content="64")
}

///|
test "hash_secret handles empty secret" {
  let hash = hash_secret("")
  inspect(hash.length(), content="64")
}

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
