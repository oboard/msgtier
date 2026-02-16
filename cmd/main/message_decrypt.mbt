///|
async fn decrypt_message_body(
  transport : &Transport,
  my_id : String,
  local_addr : String,
  msg : Message,
) -> Message? noraise {
  if msg.target_id is Some(target_id) && target_id != my_id {
    return Some(msg)
  }
  if !msg.encrypted {
    return Some(msg)
  }
  match msg.body {
    Binary(raw) =>
      match get_shared_secret(msg.source_id) {
        None => {
          log_warn(
            "Received encrypted message from \{msg.source_id} but no shared secret. Sending hello to trigger handshake.",
          )
          match msg.source_addr {
            Some(addr) => {
              let target_addr = if addr.contains("://") {
                addr
              } else {
                transport.protocol() + "://" + addr
              }
              let our_addresses = get_our_addresses(local_addr)
              let hello_msg = create_hello_message(
                my_id,
                local_addr,
                1,
                peers=our_addresses,
              )
              ignore(send_message(transport, target_addr, hello_msg))
            }
            None => ()
          }
          None
        }
        Some(_) =>
          match decrypt_from_peer(msg.source_id, raw) {
            Some(decrypted) =>
              if decrypted.length() > 0 {
                let decoded = @msgpack.decode(decrypted) catch {
                  _ => @msgpack.binary(decrypted)
                }
                Some(Message::{ ..msg, body: decoded, encrypted: false })
              } else {
                if raw.length() > 0 {
                  log_warn(
                    "DEBUG: Decryption failed for non-empty payload, returning nil",
                  )
                }
                Some(Message::{ ..msg, body: @msgpack.nil(), encrypted: false })
              }
            None => {
              log_error(
                "Failed to decrypt message from \{msg.source_id}, raw length=\{raw.length()}",
              )
              None
            }
          }
      }
    _ => Some(msg)
  }
}
