///|
/// Simple symmetric encryption using shared secret
/// Uses XOR with key stream derived from shared secret via SHA256

///|
/// Derive a key stream from shared secret and nonce
fn derive_keystream(shared_secret : Bytes, nonce : Bytes, length : Int) -> Bytes {
  let mut keystream = Bytes::new(0)
  let mut counter = 0
  while keystream.length() < length {
    // Generate block: SHA256(shared_secret || nonce || counter)
    let counter_bytes = FixedArray::make(4, b'\x00')
    counter_bytes[0] = (counter & 0xFF).to_byte()
    counter_bytes[1] = ((counter >> 8) & 0xFF).to_byte()
    counter_bytes[2] = ((counter >> 16) & 0xFF).to_byte()
    counter_bytes[3] = ((counter >> 24) & 0xFF).to_byte()
    let block = @crypto.sha256(
      shared_secret + nonce + Bytes::from_array(counter_bytes),
    )
    keystream = keystream + Bytes::from_array(block)
    counter = counter + 1
  }
  // Truncate to exact length
  let result = FixedArray::make(length, b'\x00')
  for i = 0; i < length; i = i + 1 {
    result[i] = keystream[i]
  }
  Bytes::from_array(result)
}

///|
/// Encrypt data using shared secret
/// Format: nonce (8 bytes) || ciphertext
pub fn encrypt(shared_secret : Bytes, plaintext : Bytes) -> Bytes {
  // Generate random nonce from timestamp
  let t = @env.now()
  let nonce = FixedArray::make(8, b'\x00')
  for i = 0; i < 8; i = i + 1 {
    nonce[i] = ((t >> (i * 8)) & 0xFFUL).to_byte()
  }
  let nonce_bytes = Bytes::from_array(nonce)

  // Derive keystream
  let keystream = derive_keystream(shared_secret, nonce_bytes, plaintext.length())

  // XOR plaintext with keystream
  let ciphertext = FixedArray::make(plaintext.length(), b'\x00')
  for i = 0; i < plaintext.length(); i = i + 1 {
    ciphertext[i] = plaintext[i] ^ keystream[i]
  }

  // Return nonce || ciphertext
  nonce_bytes + Bytes::from_array(ciphertext)
}

///|
/// Decrypt data using shared secret
/// Input format: nonce (8 bytes) || ciphertext
pub fn decrypt(shared_secret : Bytes, encrypted : Bytes) -> Bytes? {
  if encrypted.length() < 8 {
    return None
  }

  // Extract nonce
  let nonce = FixedArray::make(8, b'\x00')
  for i = 0; i < 8; i = i + 1 {
    nonce[i] = encrypted[i]
  }
  let nonce_bytes = Bytes::from_array(nonce)

  // Extract ciphertext
  let ciphertext_len = encrypted.length() - 8
  let ciphertext = FixedArray::make(ciphertext_len, b'\x00')
  for i = 0; i < ciphertext_len; i = i + 1 {
    ciphertext[i] = encrypted[i + 8]
  }

  // Derive keystream
  let keystream = derive_keystream(shared_secret, nonce_bytes, ciphertext_len)

  // XOR ciphertext with keystream
  let plaintext = FixedArray::make(ciphertext_len, b'\x00')
  for i = 0; i < ciphertext_len; i = i + 1 {
    plaintext[i] = ciphertext[i] ^ keystream[i]
  }

  Some(Bytes::from_array(plaintext))
}
