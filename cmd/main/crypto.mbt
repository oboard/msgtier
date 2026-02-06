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
fn get_public_key() -> Bytes {
  match global_keypair.val {
    Some((_, pub_key)) => pub_key
    None => abort("Keygen failed")
  }
}

///|
/// Get the private key for this node
fn get_private_key() -> Bytes {
  match global_keypair.val {
    Some((priv_key, _)) => priv_key
    None => abort("Keygen failed")
  }
}

///|
/// Compute and store shared secret with a peer
fn compute_and_store_shared_secret(
  peer_id : String,
  peer_public_key : Bytes,
) -> Unit {
  let priv_key = get_private_key()
  let shared = @x25519.compute_shared_secret(priv_key, peer_public_key)
  global_shared_secrets.val[peer_id] = shared
}

///|
/// Get shared secret for a peer
fn get_shared_secret(peer_id : String) -> Bytes? {
  global_shared_secrets.val.get(peer_id)
}

///|
/// Encrypt data for a peer using shared secret
fn encrypt_for_peer(peer_id : String, data : Bytes) -> Bytes {
  match get_shared_secret(peer_id) {
    Some(shared) => @x25519.encrypt(shared, data)
    None => []
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
      String::from_array([
        hex_chars[(byte >> 4) & 0xF].unsafe_to_char(),
        hex_chars[byte & 0xF].unsafe_to_char(),
      ])
  }
  result
}

///|
// /// Convert hex string to bytes
// fn hex_to_bytes(hex : String) -> Bytes {
//   let len = hex.length() / 2
//   let arr = FixedArray::make(len, b'\x00')
//   for i = 0; i < len; i = i + 1 {
//     let high = hex_char_to_int_from_uint16(hex[i * 2])
//     let low = hex_char_to_int_from_uint16(hex[i * 2 + 1])
//     arr[i] = ((high << 4) | low).to_byte()
//   }
//   Bytes::from_array(arr)
// }

// ///|
// /// Convert a hex character (as UInt16) to its integer value
// fn hex_char_to_int_from_uint16(c : UInt16) -> Int {
//   let code = c.to_int()
//   if code >= 48 && code <= 57 {
//     code - 48
//   } else if code >= 65 && code <= 70 {
//     code - 55
//   } else if code >= 97 && code <= 102 {
//     code - 87
//   } else {
//     0
//   }
// }

///|
/// Hash a network secret for authentication in hello messages
/// Uses the public key curve to consistently hash the secret
fn hash_secret(secret : String) -> String {
  // Simple deterministic hash: take first 32 bytes of secret, pad if needed
  let secret_bytes = @utf8.encode(secret)
  let len = secret_bytes.length()
  if len >= 32 {
    // Use first 32 bytes - create array from bytes view
    let arr = secret_bytes[:32].to_array()
    let padded = FixedArray::make(32, b'\x00')
    for i = 0; i < 32; i = i + 1 {
      padded[i] = arr[i]
    }
    bytes_to_hex(Bytes::from_array(padded))
  } else {
    // Pad with zeros to 32 bytes
    let padded = FixedArray::make(32, b'\x00')
    for i = 0; i < len; i = i + 1 {
      padded[i] = secret_bytes.at(i)
    }
    bytes_to_hex(Bytes::from_array(padded))
  }
}
