///|
/// Wire shape for `POST /api/channels/chat[/local]` bodies.
///
/// Every field is optional so the parser tolerates partial payloads; missing
/// values collapse into the defaults inside [parse_channel_chat_request].
struct ChannelChatRequest {
  peer_id : String?
  channel_id : String?
  instance_id : String?
  channel_type : String?
  messages : Array[Json]?
  session_key : String?
  stream : Bool?
} derive(FromJson)

///|
fn parse_channel_chat_request(
  body_str : String,
) -> (String, String, String, Array[Json], String, Bool)? {
  let req : ChannelChatRequest = (@json.parse(body_str) |> @json.from_json) catch {
    _ => return None
  }
  let channel_id = match req.channel_id {
    Some(v) if v != "" => v
    _ => req.instance_id.unwrap_or("")
  }
  guard channel_id != "" else { None }
  let peer_id = req.peer_id.unwrap_or(get_config().id)
  let session_key = req.session_key.unwrap_or(
    "chat:" + get_config().id + ":" + peer_id + ":" + channel_id,
  )
  Some(
    (
      peer_id,
      channel_id,
      req.channel_type.unwrap_or(""),
      req.messages.unwrap_or([]),
      session_key,
      req.stream.unwrap_or(false),
    ),
  )
}

///|
fn extract_user_text_from_messages(messages : Array[Json]) -> String {
  let mut idx = messages.length()
  while idx > 0 {
    idx = idx - 1
    if messages[idx] is { "role": "user", "content": String(content), .. } {
      return content
    }
    // match messages[idx] {
    //   Object(obj) =>
    //     match (obj.get("role"), obj.get("content")) {
    //       (Some(String(role)), Some(String(content))) =>
    //         if role == "user" {
    //           return content
    //         }
    //       _ => ()
    //     }
    //   _ => ()
    // }
  }
  ""
}

///|
async fn proxy_channel_chat_request(
  peer_id : String,
  channel_id : String,
  channel_type : String,
  messages : Array[Json],
  session_key : String,
  stream : Bool,
) -> (Int, Json)? {
  let body : Json = {
    "peer_id": peer_id,
    "channel_id": channel_id,
    "channel_type": channel_type,
    "messages": messages,
    "session_key": session_key,
    "stream": stream,
  }
  match
    proxy_http_request(
      peer_id,
      "POST",
      "/api/channels/chat/local",
      { "Content-Type": "application/json" },
      @utf8.encode(body.stringify()),
      60000,
    ) {
    Some((status_code, _, resp_body)) => {
      let decoded = @utf8.decode(resp_body)
      let parsed = @json.parse(decoded) catch {
        _ =>
          return Some(
            (
              502,
              { "error": "invalid_channel_proxy_response", "body": decoded },
            ),
          )
      }
      Some((status_code, parsed))
    }
    None => None
  }
}

///|
fn local_channel_chat_request(
  _channel_id : String,
  channel_type : String,
  _messages : Array[Json],
  _session_key : String,
  _stream : Bool,
) -> (Int, Json) {
  (
    404,
    {
      "error": "unknown_channel_type".to_json(),
      "channel_type": channel_type.to_json(),
    },
  )
}

///|
fn channel_target_id(peer_id : String, channel_id : String) -> String {
  "channel::" + peer_id + "::" + channel_id
}

///|
async fn finish_channel_chat_request(
  peer_id : String,
  channel_id : String,
  messages : Array[Json],
  response_body : Json,
) -> Unit {
  let my_id = get_config().id
  let target_id = channel_target_id(peer_id, channel_id)
  let prompt = extract_user_text_from_messages(messages)
  if prompt != "" {
    emit_channel_chat_message(my_id, target_id, prompt)
  }
  match response_body {
    Object(obj) =>
      match obj.get("message") {
        Some(Object(msg_obj)) =>
          match msg_obj.get("content") {
            Some(String(content)) =>
              emit_channel_chat_message(target_id, my_id, content)
            _ => ()
          }
        _ => ()
      }
    _ => ()
  }
}

///|
async fn channel_chat_handler(
  body_str : String,
  local_only : Bool,
) -> @mocket.HttpResponse {
  match parse_channel_chat_request(body_str) {
    Some((peer_id, channel_id, channel_type, messages, session_key, stream)) => {
      let my_id = get_config().id
      let response = if local_only || peer_id == my_id {
        local_channel_chat_request(
          channel_id, channel_type, messages, session_key, stream,
        )
      } else {
        match
          proxy_channel_chat_request(
            peer_id, channel_id, channel_type, messages, session_key, stream,
          ) {
          Some(resp) => resp
          None =>
            (
              504,
              {
                "error": "channel_proxy_timeout".to_json(),
                "peer_id": peer_id.to_json(),
              },
            )
        }
      }
      let (status_code, response_body) = response
      if status_code >= 200 && status_code < 300 {
        finish_channel_chat_request(
          peer_id, channel_id, messages, response_body,
        )
      }
      @mocket.HttpResponse::new(status_code_from_int(status_code)).body(
        response_body,
      )
    }
    None =>
      json_error(
        BadRequest,
        "invalid_channel_chat_request",
        "invalid channel chat request",
      )
  }
}
