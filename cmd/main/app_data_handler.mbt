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
fn decode_binary_payload(raw : Bytes) -> @msgpack.Value {
  @msgpack.decode(raw) catch {
    _ => @msgpack.binary(raw)
  }
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
      // If we receive a response, we can stop broadcasting/retrying the original request
      remove_pending_message_by_id(correlation_id) |> ignore
      if check_and_mark_processed(msg.id, msg.timestamp) {
        log_warn("Duplicate or expired response \{msg.id} ignored")
        return
      }
      log_info("Received data response from \{msg.source_id}:")
      let final_data = match data_value {
        Binary(raw) => decode_binary_payload(raw)
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
      let data_content = match data_value {
        Binary(raw_data) => decode_binary_payload(raw_data)
        _ => data_value
      }
      root.spawn_bg(async fn() {
        let content_str = if data_content is String(content) {
          content
        } else {
          ""
        }
        // Trim whitespace and remove null bytes from content string
        let cleaned = StringBuilder::new()
        for c in content_str {
          if c != '\u0000' {
            cleaned.write_char(c)
          }
        }
        let content_str = cleaned.to_string().trim().to_string()
        log_info(
          "DEBUG: Handling data message. Encrypted=\{msg.encrypted}, Content='\{content_str}'",
        )
        match execute_script_handler(content_str) {
          Some(output) => {
            let response_data = output.to_msgpack()
            let is_encrypted = get_shared_secret(msg.source_id) is Some(_)
            let response_msg = Message::new(
              kind="script",
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
