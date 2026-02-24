///|
test "hash_secret produces consistent hash" {
  let secret = "test_secret"
  let hash1 = hash_secret(secret)
  let hash2 = hash_secret(secret)
  inspect(bytes_to_hex(hash1) == bytes_to_hex(hash2), content="true")
}

///|
test "encryption and decryption roundtrip" {
  // Setup config
  global_config.val = Some({
    id: "test_node",
    secret: "test_secret_123",
    peers: [],
    listeners: [],
    scripts: None,
    web_api: None,
    metadata: None,
    log: None,
    port: None,
    relay_network_whitelist: None,
    relay_all_peer_rpc: None,
    foreign_relay_bps_limit: None,
    upload_dir: None,
    disable_encryption: None,
  })

  let message_id = "msg-12345"
  let data = b"Hello World"

  // Encrypt
  let encrypted = encrypt_with_message_key(message_id, data)

  // Decrypt
  let decrypted = decrypt_with_message_key(message_id, encrypted)

  match decrypted {
    Some(d) => inspect(d, content="b\"Hello World\"")
    None => fail("Decryption failed")
  }
}

///|
test "decryption fails with wrong message id" {
  // Setup config
  global_config.val = Some({
    id: "test_node",
    secret: "test_secret_123",
    peers: [],
    listeners: [],
    scripts: None,
    web_api: None,
    metadata: None,
    log: None,
    port: None,
    relay_network_whitelist: None,
    relay_all_peer_rpc: None,
    foreign_relay_bps_limit: None,
    upload_dir: None,
    disable_encryption: None,
  })

  let message_id = "msg-original"
  let wrong_id = "msg-wrong"
  let data = b"Secret Data"

  let encrypted = encrypt_with_message_key(message_id, data)

  // Try decrypt with wrong ID (different key)
  // Note: Depending on implementation, this might return garbage (Some) or fail (None).
  // We just want to ensure it doesn't return the original data.
  let result = decrypt_with_message_key(wrong_id, encrypted)

  match result {
    Some(d) => inspect(d == data, content="false")
    None => inspect(true, content="true")
  }
}

///|
test "decryption fails with wrong secret" {
  // Setup config
  global_config.val = Some({
    id: "test_node",
    secret: "secret_A",
    peers: [],
    listeners: [],
    scripts: None,
    web_api: None,
    metadata: None,
    log: None,
    port: None,
    relay_network_whitelist: None,
    relay_all_peer_rpc: None,
    foreign_relay_bps_limit: None,
    upload_dir: None,
    disable_encryption: None,
  })

  let message_id = "msg-1"
  let data = b"Data"

  let encrypted = encrypt_with_message_key(message_id, data)

  // Change secret
  global_config.val = Some({
    id: "test_node",
    secret: "secret_B", // Different secret
    peers: [],
    listeners: [],
    scripts: None,
    web_api: None,
    metadata: None,
    log: None,
    port: None,
    relay_network_whitelist: None,
    relay_all_peer_rpc: None,
    foreign_relay_bps_limit: None,
    upload_dir: None,
    disable_encryption: None,
  })

  let result = decrypt_with_message_key(message_id, encrypted)

  match result {
    Some(d) => inspect(d == data, content="false")
    None => inspect(true, content="true")
  }
}
