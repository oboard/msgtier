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
  guard pub_key is Some(_) && priv_key is Some(_) else {
    fail("expected some values")
  }
  guard pub_key is Some(pk) && priv_key is Some(sk) else {
    fail("expected some values")
  }
  inspect(pk.length() == 32, content="true")
  inspect(sk.length() == 32, content="true")
}

///|
test "serialize_public_key produces hex string" {
  let key : Bytes = b"\x00\x11\x22\x33\x44\x55\x66\x77\x88\x99\xaa\xbb\xcc\xdd\xee\xff\x00\x11\x22\x33\x44\x55\x66\x77\x88\x99\xaa\xbb\xcc\xdd\xee\xff"
  let serialized = serialize_public_key(key)
  inspect(serialized.length(), content="64")
}

///|
test "deserialize_public_key rejects invalid lengths" {
  inspect(deserialize_public_key(""), content="None")
  inspect(deserialize_public_key("0011"), content="None")
}

///|
test "deserialize_public_key accepts valid 64 char hex" {
  let hex_valid = "0011223344556677889900aabbccddee0011223344556677889900aabbccddee"
  inspect(hex_valid.length(), content="64")
  let result = deserialize_public_key(hex_valid)
  guard result is Some(_) else { fail("expected some value") }
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
test "encrypt_for_peer returns Some with valid shared secret" {
  init_keypair()
  let (_peer_priv, peer_pub) = @x25519.generate_keypair()
  compute_and_store_shared_secret("peer2", peer_pub)
  let data : Bytes = b"test data"
  let encrypted = encrypt_for_peer("peer2", data)
  guard encrypted is Some(_) else { fail("expected some value") }
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
