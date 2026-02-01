///|
/// Global X25519 key pair for this node (private_key, public_key)
let global_keypair : Ref[(Bytes, Bytes)?] = Ref::new(None)

///|
/// Shared secrets with peers: peer_id -> shared_secret
let global_shared_secrets : Ref[Map[String, Bytes]] = Ref::new({})

///|
/// Initialize the X25519 key pair for this node
fn init_keypair() -> Unit {
  let (priv_key, pub_key) = @x25519.generate_keypair()
  global_keypair.val = Some((priv_key, pub_key))
  println("X25519 key pair generated successfully")
}

///|
/// Get the public key for this node
fn get_public_key() -> Bytes? {
  match global_keypair.val {
    Some((_, pub_key)) => Some(pub_key)
    None => None
  }
}

///|
/// Get the private key for this node
fn get_private_key() -> Bytes? {
  match global_keypair.val {
    Some((priv_key, _)) => Some(priv_key)
    None => None
  }
}

///|
/// Serialize a public key to hex string
fn serialize_public_key(key : Bytes) -> String {
  bytes_to_hex(key)
}

///|
/// Deserialize a public key from hex string
fn deserialize_public_key(s : String) -> Bytes? {
  if s.length() != 64 {
    // 32 bytes = 64 hex chars
    return None
  }
  Some(hex_to_bytes(s))
}

///|
/// Compute and store shared secret with a peer
fn compute_and_store_shared_secret(
  peer_id : String,
  peer_public_key : Bytes,
) -> Unit {
  match get_private_key() {
    Some(priv_key) => {
      let shared = @x25519.compute_shared_secret(priv_key, peer_public_key)
      global_shared_secrets.val[peer_id] = shared
      println("Computed shared secret with peer \{peer_id}")
    }
    None => println("No private key available")
  }
}

///|
/// Get shared secret for a peer
fn get_shared_secret(peer_id : String) -> Bytes? {
  global_shared_secrets.val.get(peer_id)
}

///|
/// Encrypt data for a peer using shared secret
fn encrypt_for_peer(peer_id : String, data : Bytes) -> Bytes? {
  match get_shared_secret(peer_id) {
    Some(shared) => Some(@x25519.encrypt(shared, data))
    None => {
      println("No shared secret with peer \{peer_id}")
      None
    }
  }
}

///|
/// Decrypt data from a peer using shared secret
fn decrypt_from_peer(peer_id : String, encrypted : Bytes) -> Bytes? {
  match get_shared_secret(peer_id) {
    Some(shared) => @x25519.decrypt(shared, encrypted)
    None => {
      println("No shared secret with peer \{peer_id}")
      None
    }
  }
}

///|
/// Convert bytes to hex string
fn bytes_to_hex(data : Bytes) -> String {
  let hex_chars = "0123456789abcdef"
  let mut result = ""
  for i = 0; i < data.length(); i = i + 1 {
    let byte = data.at(i).to_int()
    result = result +
      hex_chars[(byte >> 4) & 0xF].to_string() +
      hex_chars[byte & 0xF].to_string()
  }
  result
}

///|
/// Convert hex string to bytes
fn hex_to_bytes(hex : String) -> Bytes {
  let len = hex.length() / 2
  let arr = FixedArray::make(len, b'\x00')
  for i = 0; i < len; i = i + 1 {
    let high = hex_char_to_int_from_uint16(hex[i * 2])
    let low = hex_char_to_int_from_uint16(hex[i * 2 + 1])
    arr[i] = ((high << 4) | low).to_byte()
  }
  Bytes::from_array(arr)
}

///|
/// Convert a hex character (as UInt16) to its integer value
fn hex_char_to_int_from_uint16(c : UInt16) -> Int {
  let code = c.to_int()
  if code >= 48 && code <= 57 {
    code - 48
  } else if code >= 65 && code <= 70 {
    code - 55
  } else if code >= 97 && code <= 102 {
    code - 87
  } else {
    0
  }
}

///|
/// Convert bytes to UTF-8 string
fn bytes_to_string(data : Bytes) -> String {
  let mut result = ""
  let mut i = 0
  while i < data.length() {
    let b = data.at(i).to_int()
    if b < 128 {
      result = result + b.unsafe_to_char().to_string()
      i = i + 1
    } else if (b & 0xE0) == 0xC0 && i + 1 < data.length() {
      let b2 = data.at(i + 1).to_int()
      let code_point = ((b & 0x1F) << 6) | (b2 & 0x3F)
      result = result + code_point.unsafe_to_char().to_string()
      i = i + 2
    } else if (b & 0xF0) == 0xE0 && i + 2 < data.length() {
      let b2 = data.at(i + 1).to_int()
      let b3 = data.at(i + 2).to_int()
      let code_point = ((b & 0x0F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F)
      result = result + code_point.unsafe_to_char().to_string()
      i = i + 3
    } else if (b & 0xF8) == 0xF0 && i + 3 < data.length() {
      let b2 = data.at(i + 1).to_int()
      let b3 = data.at(i + 2).to_int()
      let b4 = data.at(i + 3).to_int()
      let code_point = ((b & 0x07) << 18) |
        ((b2 & 0x3F) << 12) |
        ((b3 & 0x3F) << 6) |
        (b4 & 0x3F)
      result = result + code_point.unsafe_to_char().to_string()
      i = i + 4
    } else {
      i = i + 1
    }
  }
  result
}

///|
/// Convert string to bytes (UTF-8)
fn string_to_bytes(s : String) -> Bytes {
  @utf8.encode(s)
}

///|
/// Encrypt a string message for a specific peer
fn encrypt_message_for_peer(peer_id : String, message : String) -> String? {
  let data = string_to_bytes(message)
  match encrypt_for_peer(peer_id, data) {
    Some(encrypted) => Some(bytes_to_hex(encrypted))
    None => None
  }
}

///|
/// Decrypt a hex-encoded message from a peer
fn decrypt_message_from_peer(
  peer_id : String,
  encrypted_hex : String,
) -> String? {
  let encrypted = hex_to_bytes(encrypted_hex)
  match decrypt_from_peer(peer_id, encrypted) {
    Some(decrypted) => Some(bytes_to_string(decrypted))
    None => None
  }
}
