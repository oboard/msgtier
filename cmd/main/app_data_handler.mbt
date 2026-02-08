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
      log_info("Received data response from \{msg.source_id}:")
      let final_data = match data_value {
        Binary(raw) => {
          let payload_bytes = if msg.encrypted {
            match decrypt_from_peer(msg.source_id, raw) {
              Some(decrypted) => decrypted
              None => {
                log_error("Failed to decrypt response from \{msg.source_id}")
                b""
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
          } else {
            data_value
          }
        }
        _ => data_value
      }
      log_debug(final_data.to_string().unwrap_or("error"))
      handle_data_response(correlation_id, final_data, msg.source_id)
    }
    None => {
      // Extract raw binary data or use String directly

      log_debug(
        "DEBUG: Processing data message from \{msg.source_id}, encrypted=\{msg.encrypted}",
      )
      let data_content = if msg.encrypted && data_value is Binary(raw_data) {
        @msgpack.decode(
          match decrypt_from_peer(msg.source_id, raw_data) {
            Some(decrypted) => {
              log_debug("DEBUG: Decrypted message from \{msg.source_id}")
              decrypted
            }
            None => {
              log_error(
                "Failed to decrypt message from \{msg.source_id}, raw length=\{raw_data.length()}",
              )
              raw_data
            }
          },
        ) catch {
          _ => @msgpack.nil()
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
