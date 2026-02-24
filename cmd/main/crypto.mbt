///|
pub fn bytes_to_hex(bytes : Bytes) -> String {
  let len = bytes.length()
  let sb = StringBuilder::new(size_hint=len * 2)
  let hex_chars = [
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
  ]
  for i = 0; i < len; i = i + 1 {
    let b = bytes[i].to_int()
    let h1 = (b >> 4) & 0xF
    let h2 = b & 0xF
    sb.write_char(hex_chars[h1])
    sb.write_char(hex_chars[h2])
  }
  sb.to_string()
}

///|
pub fn hash_secret(secret : String) -> Bytes {
  let secret_bytes = @utf8.encode(secret)
  let hash = @crypto.sha256(secret_bytes)
  Bytes::from_array(hash)
}

///|
/// Compute encryption key for a message using network secret and message ID
/// Key = SHA256(secret + message_id)
pub fn compute_message_key(message_id : String) -> Bytes {
  let secret = get_config().secret
  let input = secret + message_id
  let input_bytes = @utf8.encode(input)
  let hash = @crypto.sha256(input_bytes)
  Bytes::from_array(hash)
}

///|
/// Encrypt data using message-specific key
pub fn encrypt_with_message_key(message_id : String, data : Bytes) -> Bytes {
  let config = get_config()
  if !config.is_encrypt() {
    return data
  }
  let key = compute_message_key(message_id)
  @x25519.encrypt(key, data)
}

///|
/// Decrypt data using message-specific key
pub fn decrypt_with_message_key(
  message_id : String,
  encrypted : Bytes,
) -> Bytes? {
  let key = compute_message_key(message_id)
  @x25519.decrypt(key, encrypted)
}
