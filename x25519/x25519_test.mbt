///|
test "generate_keypair" {
  let (priv_key, pub_key) = generate_keypair()
  inspect(priv_key.length(), content="32")
  inspect(pub_key.length(), content="32")
}

///|
test "shared_secret_agreement" {
  // Alice generates keypair
  let (alice_priv, alice_pub) = generate_keypair()

  // Bob generates keypair
  let (bob_priv, bob_pub) = generate_keypair()

  // Both compute shared secret
  let alice_shared = compute_shared_secret(alice_priv, bob_pub)
  let bob_shared = compute_shared_secret(bob_priv, alice_pub)

  // Shared secrets should match
  inspect(alice_shared.length(), content="32")
  inspect(bob_shared.length(), content="32")
  inspect(alice_shared == bob_shared, content="true")
}

///|
test "encrypt_decrypt" {
  let (alice_priv, _) = generate_keypair()
  let (_, bob_pub) = generate_keypair()

  // Compute shared secret
  let shared = compute_shared_secret(alice_priv, bob_pub)

  // Encrypt message
  let message = b"Hello, World!"
  let encrypted = encrypt(shared, message)

  // Decrypt
  let decrypted = decrypt(shared, encrypted)
  inspect(decrypted, content="Some(b\"Hello, World!\")")
}
