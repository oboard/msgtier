///|
/// Global X25519 key pair for this node (private_key, public_key)
let global_keypair : Ref[(Bytes, Bytes)?] = Ref::new(None)

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
/// Shared secrets with peers: peer_id -> shared_secret
let global_shared_secrets : Map[String, Bytes] = {}

///|
/// Initialize the X25519 key pair for this node
fn init_keypair(secret : String) -> Unit {
  let priv_key = match secret {
    "" => @x25519.generate_private_key()
    s => {
      let secret_bytes = @utf8.encode(s)
      let hash = @crypto.sha256(secret_bytes)
      @x25519.clamp_scalar(Bytes::from_array(hash))
    }
  }
  let pub_key = @x25519.compute_public_key(priv_key)
  global_keypair.val = Some((priv_key, pub_key))
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
/// Clear stored shared secret for a peer (force re-computation)
fn clear_shared_secret(peer_id : String) -> Unit {
  global_shared_secrets.remove(peer_id)
  log_debug("DEBUG: Cleared shared secret for \{peer_id}")
}

///|
/// Compute and store shared secret with a peer
fn compute_and_store_shared_secret(
  peer_id : String,
  peer_public_key : Bytes,
) -> Unit {
  if peer_public_key.length() == 0 {
    log_warn(
      "Attempted to compute shared secret with empty public key for \{peer_id}",
    )
    return
  }
  let priv_key = get_private_key()
  let shared = @x25519.compute_shared_secret(priv_key, peer_public_key)
  global_shared_secrets[peer_id] = shared
  log_debug("DEBUG: Computed shared secret for \{peer_id}: \{(shared)}")
}

///|
/// Get shared secret for a peer
fn get_shared_secret(peer_id : String) -> Bytes? {
  match global_shared_secrets.get(peer_id) {
    Some(s) => Some(s)
    None =>
      // Fallback: try to compute from PeerManager
      match get_global_peer_manager().get_peer(peer_id) {
        Some(peer) =>
          if peer.public_key.length() > 0 {
            compute_and_store_shared_secret(peer_id, peer.public_key)
            global_shared_secrets.get(peer_id)
          } else {
            None
          }
        None => None
      }
  }
}

///|
/// Encrypt data for a peer using shared secret
fn encrypt_for_peer(peer_id : String, data : Bytes) -> Bytes {
  match get_shared_secret(peer_id) {
    Some(shared) => {
      log_debug("DEBUG: Encrypting for \{peer_id} with secret \{(shared)}...")
      @x25519.encrypt(shared, data)
    }
    None => []
  }
}

///|
/// Decrypt data from a peer using shared secret
fn decrypt_from_peer(peer_id : String, encrypted : Bytes) -> Bytes? {
  match get_shared_secret(peer_id) {
    Some(shared) =>
      match @x25519.decrypt(shared, encrypted) {
        Some(decrypted) => Some(decrypted)
        None => {
          log_warn(
            "Decryption failed for peer \{peer_id} (shared secret mismatch?)",
          )
          // If decryption fails, maybe the secret is stale?
          // We could try to clear it here, but that might lead to loops if not careful.
          // For now, let's just return None.
          // Optional: clear_shared_secret(peer_id) // risky?
          None
        }
      }
    None => None
  }
}
