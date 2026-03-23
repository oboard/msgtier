///|
fn parse_channel_chat_request(
  body_str : String,
) -> (String, String, String, Array[Json], String, Bool)? {
  let parsed = @json.parse(body_str) catch { _ => return None }
  guard parsed is Object(obj) else { None }
  let peer_id0 = @jsonx.get(obj, "peer_id")
  let channel_id0 = @jsonx.get(obj, "channel_id")
  let instance_id = @jsonx.get(obj, "instance_id")
  let channel_id = first_non_empty(channel_id0, instance_id).unwrap_or("")
  guard channel_id != "" else { None }
  let channel_type0 = @jsonx.get(obj, "channel_type")
  let messages0 = @jsonx.get(obj, "messages")
  let session_key0 = @jsonx.get(obj, "session_key")
  let stream0 = @jsonx.get(obj, "stream")
  let peer_id = peer_id0.unwrap_or(get_config().id)
  let session_key = session_key0.unwrap_or(
    "chat:" + get_config().id + ":" + peer_id + ":" + channel_id,
  )
  Some(
    (
      peer_id,
      channel_id,
      channel_type0.unwrap_or("openclaw"),
      messages0.unwrap_or([]),
      session_key,
      stream0.unwrap_or(false),
    ),
  )
}

///|
fn extract_user_text_from_messages(messages : Array[Json]) -> String {
  let mut idx = messages.length()
  while idx > 0 {
    idx = idx - 1
    match messages[idx] {
      Object(obj) =>
        match (obj.get("role"), obj.get("content")) {
          (Some(String(role)), Some(String(content))) =>
            if role == "user" {
              return content
            }
          _ => ()
        }
      _ => ()
    }
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
async fn local_channel_chat_request(
  channel_id : String,
  channel_type : String,
  messages : Array[Json],
  session_key : String,
  stream : Bool,
) -> (Int, Json) {
  match channel_type {
    "openclaw" =>
      chat_with_openclaw_local(channel_id, messages, session_key, stream)
    _ =>
      (
        404,
        {
          "error": "unknown_channel_type".to_json(),
          "channel_type": channel_type.to_json(),
        },
      )
  }
}

///|
async fn finish_channel_chat_request(
  peer_id : String,
  channel_id : String,
  messages : Array[Json],
  response_body : Json,
) -> Unit {
  let my_id = get_config().id
  let target_id = openclaw_channel_target_id(peer_id, channel_id)
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
fn extract_channel_response_content(response_body : Json) -> String {
  match response_body {
    Object(obj) =>
      match obj.get("message") {
        Some(Object(msg_obj)) =>
          match msg_obj.get("content") {
            Some(String(content)) => content
            _ => ""
          }
        _ => ""
      }
    _ => ""
  }
}

///|
fn split_stream_chunks(text : String) -> Array[String] {
  let chunks : Array[String] = []
  if text == "" {
    return chunks
  }
  let mut current = ""
  for part in text.split(" ") {
    let token = part.to_string()
    let next = if current == "" { token } else { current + " " + token }
    if next.length() >= 24 {
      chunks.push(next)
      current = ""
    } else {
      current = next
    }
  }
  if current != "" {
    chunks.push(current)
  }
  if chunks.is_empty() {
    chunks.push(text)
  }
  chunks
}

///|
fn make_sse_event_chunk(event_name : String, payload : Json) -> String {
  "event: " + event_name + "\n" + "data: " + payload.stringify() + "\n\n"
}

///|
fn parse_sse_done_payload(raw : String) -> Json? {
  let blocks = raw.split("\n\n").to_array()
  let mut idx = blocks.length()
  while idx > 0 {
    idx = idx - 1
    let block = blocks[idx]
    let mut event_name = ""
    let mut data = ""
    for raw_line in block.split("\n") {
      let line = raw_line.trim().to_string()
      if line.has_prefix("event:") {
        event_name = line[6:].trim().to_string()
      } else if line.has_prefix("data:") {
        data = data + line[5:].trim().to_string()
      }
    }
    if event_name == "done" && data != "" {
      return Some(@json.parse(data)) catch { _ => None }
    }
  }
  None
}

///|
fn channel_stream_headers() -> Map[String, String] {
  {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    "Connection": "keep-alive",
  }
}

///|
fn make_channel_stream_events(
  peer_id : String,
  channel_id : String,
  channel_type : String,
  response_body : Json,
) -> Array[String] {
  let chunks : Array[String] = []
  chunks.push(
    make_sse_event_chunk("start", {
      "peer_id": peer_id,
      "channel_id": channel_id,
      "channel_type": channel_type,
    }),
  )
  let content = extract_channel_response_content(response_body)
  for chunk in split_stream_chunks(content) {
    chunks.push(make_sse_event_chunk("delta", { "delta": chunk }))
  }
  chunks.push(make_sse_event_chunk("done", response_body))
  chunks
}

///|
async fn channel_chat_stream_handler(
  conn : @http.ServerConnection,
  body_str : String,
  local_only : Bool,
) -> Unit {
  match parse_channel_chat_request(body_str) {
    Some((peer_id, channel_id, channel_type, messages, session_key, _)) => {
      let my_id = get_config().id
      if !local_only && peer_id != my_id {
        proxy_channel_chat_request_stream(
          conn, body_str, peer_id, channel_id, messages,
        )
        return
      }
      let response = if local_only || peer_id == my_id {
        local_channel_chat_request(
          channel_id, channel_type, messages, session_key, false,
        )
      } else {
        match
          proxy_channel_chat_request(
            peer_id, channel_id, channel_type, messages, session_key, false,
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
      if status_code < 200 || status_code >= 300 {
        conn
        ..send_response(status_code, status_text(status_code), extra_headers={
          "Content-Type": "application/json",
        })
        ..write(response_body.stringify())
        .end_response()
        return
      }
      conn.send_response(200, "OK", extra_headers=channel_stream_headers())
      for
        event_chunk in make_channel_stream_events(
          peer_id, channel_id, channel_type, response_body,
        ) {
        conn.write(event_chunk)
        @async.sleep(10)
      }
      finish_channel_chat_request(peer_id, channel_id, messages, response_body)
      conn.end_response()
    }
    None =>
      conn
      ..send_response(400, "Bad Request", extra_headers={
        "Content-Type": "application/json",
      })
      ..write({ "error": "invalid_channel_chat_request" }.to_json().stringify())
      .end_response()
  }
}

///|
async fn proxy_channel_chat_request_stream(
  conn : @http.ServerConnection,
  body_str : String,
  peer_id : String,
  channel_id : String,
  messages : Array[Json],
) -> Unit {
  let timeout_ms = 60000
  let timeout_ms_uint = timeout_ms.reinterpret_as_uint()
  let timeout_ms_u64 = timeout_ms.to_uint64()
  let req_id = @nanoid.nanoid().unwrap_or(@env.now().to_string())
  add_stream_request(req_id)
  let body = @utf8.encode(body_str)
  let body_map : Map[String, @msgpack.Value] = Map::new()
  body_map["method"] = @msgpack.string("POST")
  body_map["path"] = @msgpack.string("/api/channels/chat/local/stream")
  body_map["headers"] = headers_to_msgpack({
    "Content-Type": "application/json",
  })
  body_map["body"] = @msgpack.binary(body)
  body_map["stream_mode"] = @msgpack.string("frame_v1")
  let config = get_config()
  let msg = Message::new(
    kind="http_proxy",
    source_id=config.id,
    relay=1,
    version=app_state.version,
    body=@msgpack.map(body_map),
    encrypted=config.is_encrypt(),
    timeout_ms=timeout_ms_uint,
  )
  let msg = { ..msg, target_id: Some(peer_id), payload: Some(req_id) }
  if !send_message_now(peer_id, msg) {
    add_pending_message(msg)
  }
  let start = @env.now()
  let mut sent_response = false
  let mut sse_buffer = ""
  for ;; {
    let now = @env.now()
    if now - start > timeout_ms_u64 {
      if !sent_response {
        conn
        ..send_response(504, "Gateway Timeout", extra_headers={
          "Content-Type": "application/json",
        })
        ..write(
          { "error": "channel_proxy_timeout", "peer_id": peer_id }
          .to_json()
          .stringify(),
        )
        .end_response()
      } else {
        conn.end_response()
      }
      return
    }
    let remaining_ms_u64 = timeout_ms_u64 - (now - start)
    let wait_ms = if remaining_ms_u64 > 1000UL {
      1000
    } else {
      remaining_ms_u64.to_int()
    }
    match wait_stream_chunk(req_id, wait_ms) {
      Some((chunk, done, headers_opt)) => {
        if !sent_response {
          let resp_headers = match headers_opt {
            Some(h) => h
            None => channel_stream_headers()
          }
          let status_code = match resp_headers.get("status") {
            Some(s) => @strconv.parse_int(s) catch { _ => 200 }
            None => 200
          }
          resp_headers.remove("status")
          if !resp_headers.contains("Content-Type") {
            resp_headers["Content-Type"] = "text/event-stream"
          }
          conn.send_response(
            status_code,
            status_text(status_code),
            extra_headers=resp_headers,
          )
          sent_response = true
        }
        if chunk.length() > 0 {
          let chunk_text = @utf8.decode(chunk) catch { _ => "" }
          sse_buffer = sse_buffer + chunk_text
          conn.write(chunk)
        }
        if done {
          match parse_sse_done_payload(sse_buffer) {
            Some(response_body) =>
              finish_channel_chat_request(
                peer_id, channel_id, messages, response_body,
              )
            None => ()
          }
          conn.end_response()
          return
        }
      }
      None => ()
    }
  }
}

///|
async fn channel_chat_handler(
  conn : @http.ServerConnection,
  body_str : String,
  local_only : Bool,
) -> Unit {
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
      conn
      ..send_response(status_code, status_text(status_code), extra_headers={
        "Content-Type": "application/json",
      })
      ..write(response_body.stringify())
      .end_response()
    }
    None =>
      conn
      ..send_response(400, "Bad Request", extra_headers={
        "Content-Type": "application/json",
      })
      ..write({ "error": "invalid_channel_chat_request" }.to_json().stringify())
      .end_response()
  }
}

///|
async fn openclaw_chat_handler(
  conn : @http.ServerConnection,
  body_str : String,
  local_only : Bool,
) -> Unit {
  channel_chat_handler(conn, body_str, local_only)
}
