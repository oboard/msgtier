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
      log_debug(data_value.to_string().unwrap_or("error"))
      handle_data_response(correlation_id, data_value, msg.source_id)
    }
    None =>
      match data_value {
        Binary(raw_data) => {
          log_debug(
            "DEBUG: Processing data message from \{msg.source_id}, encrypted=\{msg.encrypted}",
          )
          let data_content = if msg.encrypted {
            match decrypt_from_peer(msg.source_id, raw_data) {
              Some(decrypted) => {
                log_debug("DEBUG: Decrypted message from \{msg.source_id}")
                decrypted
              }
              None => {
                log_error(
                  "Failed to decrypt message from \{msg.source_id}, raw=\{raw_data}",
                )
                raw_data
              }
            }
          } else {
            raw_data
          }
          root.spawn_bg(fn() {
            let content_str = @utf8.decode(data_content) catch {
              _ => {
                log_warn("UTF8 decode Malformed")
                return
              }
            }
            match execute_script_handler(content_str) {
              Some(output) => {
                let response_msg = Message::new(
                  kind="data",
                  source_id=id,
                  source_addr=local_addr,
                  relay=1,
                  data=output.to_msgpack(),
                  payload=msg.id,
                )
                add_pending_message(response_msg)
                log_info(
                  "DataResponse: queued id=\{response_msg.id} correlation=\{msg.id} to=\{msg.source_id}",
                )
              }
              None =>
                log_warn(
                  "No scripts configured, received data: \{data_content}",
                )
            }
          })
        }
        _ =>
          log_warn("Data message without binary payload from \{msg.source_id}")
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
    _ =>
      resolve_request(
        correlation_id,
        {},
        @utf8.encode(response_data.to_string().unwrap_or("error")),
      )
  }
}
