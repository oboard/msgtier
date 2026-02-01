///|
/// Global RSA key pair for this node
let global_keypair : Ref[(@rsa.RsaPublicKey, @rsa.RsaPrivateKey)?] = Ref::new(
  None,
)

///|
/// Initialize the RSA key pair for this node
/// Uses 2048-bit keys with e=65537 (standard public exponent)
fn init_keypair() -> Unit {
  try {
    let e = @bigint.BigInt::from_int(65537)
    let (pub_key, priv_key) = @rsa.generate_key_pairs(2048, e)
    global_keypair.val = Some((pub_key, priv_key))
    println("RSA key pair generated successfully")
  } catch {
    e => println("Failed to generate RSA key pair: \{e}")
  }
}

///|
/// Get the public key for this node
fn get_public_key() -> @rsa.RsaPublicKey? {
  match global_keypair.val {
    Some((pub_key, _)) => Some(pub_key)
    None => None
  }
}

///|
/// Get the private key for this node
fn get_private_key() -> @rsa.RsaPrivateKey? {
  match global_keypair.val {
    Some((_, priv_key)) => Some(priv_key)
    None => None
  }
}

///|
/// Serialize a public key to a portable string format (hex-encoded modulus:exponent)
fn serialize_public_key(key : @rsa.RsaPublicKey) -> String {
  let modulus_hex = key.get_modulus().to_hex()
  let exponent_hex = key.get_public_exponent().to_hex()
  "\{modulus_hex}:\{exponent_hex}"
}

///|
/// Deserialize a public key from a portable string format
fn deserialize_public_key(s : String) -> @rsa.RsaPublicKey? {
  // Find the separator
  let mut sep_idx = -1
  for i = 0; i < s.length(); i = i + 1 {
    if s[i] == ':' {
      sep_idx = i
      break
    }
  }
  if sep_idx < 0 {
    return None
  }
  // Build strings manually to avoid slice errors
  let mut modulus_hex = ""
  for i = 0; i < sep_idx; i = i + 1 {
    modulus_hex = modulus_hex + s[i].to_int().unsafe_to_char().to_string()
  }
  let mut exponent_hex = ""
  for i = sep_idx + 1; i < s.length(); i = i + 1 {
    exponent_hex = exponent_hex + s[i].to_int().unsafe_to_char().to_string()
  }
  let modulus = @bigint.BigInt::from_hex(modulus_hex)
  let exponent = @bigint.BigInt::from_hex(exponent_hex)
  Some(@rsa.RsaPublicKey::new(modulus~, public_exponent=exponent))
}

///|
/// Encrypt data using a peer's public key
/// Returns base64-like hex encoded ciphertext
fn encrypt_for_peer(
  peer_public_key : @rsa.RsaPublicKey,
  data : Bytes,
) -> String? {
  try {
    // RSA can only encrypt data smaller than key size - 2*hash_len - 2
    // For 2048-bit key with SHA-256: 256 - 2*32 - 2 = 190 bytes max
    let max_chunk_size = 190
    if data.length() <= max_chunk_size {
      // Single chunk encryption
      let ciphertext = @rsa.rsaes_oaep_encrypt(
        peer_public_key,
        data,
        Bytes::new(0),
      )
      Some(bytes_to_hex(ciphertext))
    } else {
      // For larger data, we need to chunk it
      // This is a simplified approach - in production, use hybrid encryption
      let mut result = ""
      let mut offset = 0
      while offset < data.length() {
        let end = if offset + max_chunk_size > data.length() {
          data.length()
        } else {
          offset + max_chunk_size
        }
        let chunk = data[offset:end].to_bytes()
        let ciphertext = @rsa.rsaes_oaep_encrypt(
          peer_public_key,
          chunk,
          Bytes::new(0),
        )
        if result.length() > 0 {
          result = result + "|"
        }
        result = result + bytes_to_hex(ciphertext)
        offset = end
      }
      Some(result)
    }
  } catch {
    e => {
      println("Encryption failed: \{e}")
      None
    }
  }
}

///|
/// Decrypt data using our private key
fn decrypt_with_private_key(encrypted_hex : String) -> Bytes? {
  match get_private_key() {
    Some(priv_key) =>
      try {
        // Check if this is chunked data (contains |)
        let mut has_separator = false
        for i = 0; i < encrypted_hex.length(); i = i + 1 {
          if encrypted_hex[i] == '|' {
            has_separator = true
            break
          }
        }
        if has_separator {
          // Split by | and decrypt each chunk
          let mut result = Bytes::new(0)
          let mut start = 0
          for i = 0; i <= encrypted_hex.length(); i = i + 1 {
            if i == encrypted_hex.length() || encrypted_hex[i] == '|' {
              if i > start {
                // Build chunk string manually
                let mut chunk = ""
                for j = start; j < i; j = j + 1 {
                  chunk = chunk +
                    encrypted_hex[j].to_int().unsafe_to_char().to_string()
                }
                let ciphertext = hex_to_bytes(chunk)
                let plaintext = @rsa.rsaes_oaep_decrypt(
                  priv_key,
                  ciphertext,
                  Bytes::new(0),
                )
                result = result + plaintext
              }
              start = i + 1
            }
          }
          Some(result)
        } else {
          let ciphertext = hex_to_bytes(encrypted_hex)
          Some(@rsa.rsaes_oaep_decrypt(priv_key, ciphertext, Bytes::new(0)))
        }
      } catch {
        e => {
          println("Decryption failed: \{e}")
          None
        }
      }
    None => {
      println("No private key available")
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
    // '0' - '9'
    code - 48
  } else if code >= 65 && code <= 70 {
    // 'A' - 'F'
    code - 55
  } else if code >= 97 && code <= 102 {
    // 'a' - 'f'
    code - 87
  } else {
    0
  }
}

///|
/// Convert bytes to UTF-8 string
fn bytes_to_string(data : Bytes) -> String {
  // Simple UTF-8 decoding - handles ASCII and basic UTF-8
  let mut result = ""
  let mut i = 0
  while i < data.length() {
    let b = data.at(i).to_int()
    if b < 128 {
      // ASCII character
      result = result + b.unsafe_to_char().to_string()
      i = i + 1
    } else if (b & 0xE0) == 0xC0 && i + 1 < data.length() {
      // 2-byte UTF-8
      let b2 = data.at(i + 1).to_int()
      let code_point = ((b & 0x1F) << 6) | (b2 & 0x3F)
      result = result + code_point.unsafe_to_char().to_string()
      i = i + 2
    } else if (b & 0xF0) == 0xE0 && i + 2 < data.length() {
      // 3-byte UTF-8
      let b2 = data.at(i + 1).to_int()
      let b3 = data.at(i + 2).to_int()
      let code_point = ((b & 0x0F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F)
      result = result + code_point.unsafe_to_char().to_string()
      i = i + 3
    } else if (b & 0xF8) == 0xF0 && i + 3 < data.length() {
      // 4-byte UTF-8
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
      // Invalid UTF-8, skip byte
      i = i + 1
    }
  }
  result
}

///|
/// Convert string to bytes (UTF-8)
fn string_to_bytes(s : String) -> Bytes {
  let encoder = @utf8.encode(s)
  encoder
}

///|
/// Encrypt a string message for a specific peer
/// Returns the encrypted hex string, or None if encryption fails
fn encrypt_message_for_peer(peer_id : String, message : String) -> String? {
  // Get peer's public key
  match get_global_peer_manager().get_peer_public_key(peer_id) {
    Some(pk_str) =>
      match deserialize_public_key(pk_str) {
        Some(peer_pub_key) => {
          let data = string_to_bytes(message)
          encrypt_for_peer(peer_pub_key, data)
        }
        None => {
          println("Failed to deserialize public key for peer \{peer_id}")
          None
        }
      }
    None => {
      println("No public key available for peer \{peer_id}")
      None
    }
  }
}
