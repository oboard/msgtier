///|
test "get_public_key returns None when keypair not initialized" {
  inspect(get_public_key(), content="None")
}

///|
test "get_private_key returns None when keypair not initialized" {
  inspect(get_private_key(), content="None")
}

///|
test "init_keypair initializes both keys" {
  init_keypair()
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
test "compute_and_store_shared_secret stores secret" {
  init_keypair()
  let (_peer_priv, peer_pub) = @x25519.generate_keypair()
  compute_and_store_shared_secret("peer1", peer_pub)
  let stored = get_shared_secret("peer1")
  guard stored is Some(_) else { fail("expected some value") }
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
