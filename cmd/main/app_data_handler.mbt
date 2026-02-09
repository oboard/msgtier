///|
let processed_messages_cache : Ref[Map[String, UInt64]] = Ref::new({})

///|
fn check_and_mark_processed(id : String, timestamp : UInt64) -> Bool {
  let now = @env.now()
  // TTL Check (30s)
  if now > timestamp && now - timestamp > 30000 {
    log_warn("Dropping expired message \{id}, age=\{now - timestamp}ms")
    return true
  }
  let cache = processed_messages_cache.val
  if cache.contains(id) {
    return true
  }
  cache[id] = now
  false
}

///|
fn handle_data_message(
  root : @async.TaskGroup[Unit],
  id : String,
  local_addr : String,
  msg : Message,
  data_value : @msgpack.Value,
) -> Unit {
  match msg.payload {
    Some(correlation_id) => {
      if check_and_mark_processed(msg.id, msg.timestamp) {
        log_warn("Duplicate or expired response \{msg.id} ignored")
        return
      }
      log_info("Received data response from \{msg.source_id}:")
      let final_data = match data_value {
        Binary(raw) => {
          let payload_bytes = if msg.encrypted {
            // Check if we have a shared secret first
            match get_shared_secret(msg.source_id) {
              None => {
                log_error("Received encrypted message from \{msg.source_id} but no shared secret found. Dropping.")
                return
              }
              Some(_) => ()
            }

            match decrypt_from_peer(msg.source_id, raw) {
              Some(decrypted) => {
                log_debug(
                  "DEBUG: Decrypted message from \{msg.source_id}, len=\{decrypted.length()}",
                )
                // Debug: print first few bytes
                if decrypted.length() > 0 {
                  // Simplified logging to avoid string replace issues
                  log_debug("DEBUG: Decrypted bytes length: \{decrypted.length()}")
                  let mut s = ""
                  for i = 0; i < decrypted.length(); i = i + 1 {
                    s = s + decrypted[i].to_int().to_string() + " "
                  }
                  log_debug("DEBUG: Decrypted bytes: \{s}")
                }
                decrypted
              }
              None => {
                log_error(
                  "Failed to decrypt message from \{msg.source_id}, raw length=\{raw.length()}",
                )
                return // Abort if decryption fails
              }
            }
          } else {
            raw
          }
          if payload_bytes.length() > 0 {
            @msgpack.decode(payload_bytes) catch {
              _ => {
                log_warn("Failed to decode response bytes")
                data_value
              }
            }
            // Handle empty payload bytes (decryption failure or empty response)
            // But if raw was not empty and we failed to decrypt (returning b""), we shouldn't fallback to data_value (which is raw)
            // If raw was empty, data_value is likely Nil or Binary(b"")
          } else if raw.length() > 0 && msg.encrypted {
            // Decryption failed (logged above), return Nil
            @msgpack.nil()
          } else {
            // Not encrypted or empty raw, return data_value
            data_value
          }
        }
        _ => data_value
      }
      log_debug(
        "DEBUG: Final response data: " +
        final_data.to_string().unwrap_or("error"),
      )
      handle_data_response(correlation_id, final_data, msg.source_id)
    }
    None => {
      // Extract raw binary data or use String directly
      // check_and_mark_processed(msg.id, msg.timestamp) has been removed from here
      // because message processing logic should be idempotent if possible,
      // or handled by the caller. But wait, user requested idempotency.
      // The issue is check_and_mark_processed was called TWICE in the provided log context?
      // No, the log shows "Duplicate or expired message ... ignored" only ONCE per ID for the *response* path in previous turn.
      // But for *request* path (None case), we also need it.

      if check_and_mark_processed(msg.id, msg.timestamp) {
        log_warn("Duplicate or expired message \{msg.id} ignored")
        return
      }
      log_debug(
        "DEBUG: Processing data message from \{msg.source_id}, encrypted=\{msg.encrypted}",
      )
      match data_value {
        Binary(b) =>
          log_debug("DEBUG: Received data_value Binary len=\{b.length()}")
        String(s) =>
          log_debug("DEBUG: Received data_value String len=\{s.length()}")
        _ => log_debug("DEBUG: Received data_value Other")
      }
      let data_content = if msg.encrypted && data_value is Binary(raw_data) {
        let decrypted_bytes = match decrypt_from_peer(msg.source_id, raw_data) {
          Some(decrypted) => {
            log_debug(
              "DEBUG: Decrypted message from \{msg.source_id}, len=\{decrypted.length()}",
            )
            // Debug: print first few bytes
            if decrypted.length() > 0 {
              // Simplified logging to avoid string replace issues
              log_debug("DEBUG: Decrypted bytes length: \{decrypted.length()}")
              let mut s = ""
              for i = 0; i < decrypted.length(); i = i + 1 {
                s = s + decrypted[i].to_int().to_string() + " "
              }
              log_debug("DEBUG: Decrypted bytes: \{s}")
            }
            decrypted
          }
          None => {
            log_error(
              "Failed to decrypt message from \{msg.source_id}, raw length=\{raw_data.length()}",
            )
            b""
          }
        }
        if decrypted_bytes.length() > 0 {
          let decoded = @msgpack.decode(decrypted_bytes) catch {
            _ => {
              log_error("DEBUG: Failed to decode decrypted bytes")
              @msgpack.nil()
            }
          }
          log_debug("DEBUG: Decoded MsgPack type: \{decoded}")
          decoded
        } else {
          // Decryption failed or empty payload
          if raw_data.length() > 0 {
            log_warn(
              "DEBUG: Decryption failed for non-empty payload, returning nil",
            )
          }
          @msgpack.nil()
        }
      } else {
        data_value
      }
      root.spawn_bg(fn() {
        let content_str = if data_content is String(content) {
          content
        } else {
          ""
        }
        // Trim whitespace from content string to avoid empty script names
        let content_str = content_str.trim().to_string()
        log_info("DEBUG: Handling data message. Encrypted=\{msg.encrypted}, Content='\{content_str}'")
        
        match execute_script_handler(content_str) {
          Some(output) => {
            let response_data_raw = output.to_msgpack()
            let (response_data, is_encrypted) = match
              get_shared_secret(msg.source_id) {
              Some(_) =>
                (
                  @msgpack.binary(
                    encrypt_for_peer(
                      msg.source_id,
                      @msgpack.encode(response_data_raw),
                    ),
                  ),
                  true,
                )
              None => {
                log_warn(
                  "No shared secret for \{msg.source_id}, sending unencrypted binary",
                )
                (@msgpack.binary(@msgpack.encode(response_data_raw)), false)
              }
            }
            let response_msg = Message::new(
              kind="data",
              source_id=id,
              source_addr=local_addr,
              target_id=msg.source_id,
              relay=1,
              body=response_data,
              encrypted=is_encrypted,
              payload=msg.payload.unwrap_or(msg.id), // Use payload (correlation_id) if available, otherwise fallback to msg.id
            )
            add_pending_message(response_msg)
            log_info(
              "DataResponse: queued id=\{response_msg.id} correlation=\{msg.id} to=\{msg.source_id} encrypted=\{is_encrypted}",
            )
          }
          None =>
            log_warn(
              "No scripts configured or script not found, received data: \{content_str}",
            )
        }
      })
    }
  }
}

///|
fn handle_data_response(
  correlation_id : String,
  response_data : @msgpack.Value,
  source_id : String,
) -> Unit {
  log_debug(
    "DataResponse: resolve correlation=\{correlation_id} from=\{source_id}",
  )
  match response_data {
    Array(arr) => {
      let strings = []
      for v in arr {
        if v is String(s) {
          strings.push(s)
        }
      }
      resolve_request(
        correlation_id,
        {},
        @utf8.encode(strings.to_json().stringify()),
      )
    }
    Map(m) => {
      // Try to extract "output" from ScriptOutput map
      let output = match m.get("output") {
        Some(String(s)) => s
        _ => response_data.to_string().unwrap_or("error")
      }
      resolve_request(correlation_id, {}, @utf8.encode(output))
    }
    _ =>
      resolve_request(
        correlation_id,
        {},
        @utf8.encode(response_data.to_string().unwrap_or("error")),
      )
  }
}
