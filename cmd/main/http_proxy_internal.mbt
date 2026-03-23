///|
fn status_text(code : Int) -> String {
  match code {
    200 => "OK"
    206 => "Partial Content"
    400 => "Bad Request"
    404 => "Not Found"
    500 => "Internal Server Error"
    502 => "Bad Gateway"
    504 => "Gateway Timeout"
    _ => "OK"
  }
}

///|
fn message_route_candidates(
  peer_id : String,
  protocol : String,
) -> Array[String] {
  let candidates : Array[String] = []
  let seen : Map[String, Bool] = {}
  let connections = get_global_connection_manager().get_peer_connections(
    peer_id,
  )
  for conn in connections {
    if conn.relay != 1 {
      continue
    }
    for addr, _ in conn.address_stats {
      if addr.has_prefix(protocol + "://") && !seen.contains(addr) {
        candidates.push(addr)
        seen[addr] = true
      }
    }
  }
  match pick_peer_address(peer_id, protocol) {
    Some(addr) =>
      if !seen.contains(addr) {
        candidates.push(addr)
        seen[addr] = true
      }
    None => ()
  }
  match pick_peer_lan_address(peer_id, protocol) {
    Some(addr) => {
      let full_addr = if addr.contains("://") {
        addr
      } else {
        protocol + "://" + addr
      }
      if !seen.contains(full_addr) {
        candidates.push(full_addr)
        seen[full_addr] = true
      }
    }
    None => ()
  }
  candidates
}

///|
fn preferred_message_transports() -> Array[&Transport] {
  let registered = get_registered_transports()
  let tcp_transports = registered.filter(fn(transport) {
    transport.protocol() == "tcp"
  })
  if tcp_transports.is_empty() {
    registered
  } else {
    tcp_transports
  }
}

///|
async fn send_message_via_route(
  protocol : String,
  target_addr : String,
  msg : Message,
) -> Bool {
  for transport in preferred_message_transports() {
    if transport.protocol() == protocol {
      return send_message(transport, target_addr, msg)
    }
  }
  false
}

///|
async fn send_message_now_with_route(
  peer_id : String,
  msg : Message,
) -> (Bool, String?, String?) {
  let transports = preferred_message_transports()

  for transport in transports {
    let protocol = transport.protocol()
    for target_addr in message_route_candidates(peer_id, protocol) {
      if send_message(transport, target_addr, msg) {
        return (true, Some(protocol), Some(target_addr))
      }
    }
  }
  (false, None, None)
}

///|
async fn send_message_now(peer_id : String, msg : Message) -> Bool {
  let (ok, _, _) = send_message_now_with_route(peer_id, msg)
  ok
}

///|
async fn proxy_http_request(
  peer_id : String,
  http_method : String,
  path : String,
  headers : Map[String, String],
  body : Bytes,
  timeout_ms : Int,
) -> (Int, Map[String, String], Bytes)? {
  let timeout_ms_uint = timeout_ms.reinterpret_as_uint()
  let req_id = @nanoid.nanoid().unwrap_or(@env.now().to_string())
  add_pending_request(req_id)
  let body_map : Map[String, @msgpack.Value] = Map::new()
  body_map["method"] = @msgpack.string(http_method)
  body_map["path"] = @msgpack.string(path)
  body_map["headers"] = headers_to_msgpack(headers)
  body_map["body"] = @msgpack.binary(body)
  let config = get_config()
  let is_encrypted = config.is_encrypt()
  let msg = Message::new(
    kind="http_proxy",
    source_id=get_config().id,
    relay=1,
    version=app_state.version,
    body=@msgpack.map(body_map),
    encrypted=is_encrypted,
    timeout_ms=timeout_ms_uint,
  )
  let msg = { ..msg, target_id: Some(peer_id), payload: Some(req_id) }
  if !send_message_now(peer_id, msg) {
    add_pending_message(msg)
  }

  match wait_for_response(req_id, timeout_ms_uint) {
    Some((data, headers)) => {
      let status_code = match headers.get("status") {
        Some(s) => @strconv.parse_int(s) catch { _ => 200 }
        None => 200
      }
      headers.remove("status")
      Some((status_code, headers, data))
    }
    None => None
  }
}

///|
async fn proxy_http_request_stream(
  peer_id : String,
  http_method : String,
  path : String,
  headers : Map[String, String],
  body : Bytes,
  timeout_ms : Int,
  filename : String?,
  conn : @http.ServerConnection,
) -> Unit {
  let timeout_ms_uint = timeout_ms.reinterpret_as_uint()
  let timeout_ms_u64 = timeout_ms.to_uint64()
  let req_id = @nanoid.nanoid().unwrap_or(@env.now().to_string())
  log_bench(
    "proxy_stream_start",
    details="req=\{req_id} peer=\{peer_id} path=\{path}",
  )
  add_stream_request(req_id)
  let body_map : Map[String, @msgpack.Value] = Map::new()
  body_map["method"] = @msgpack.string(http_method)
  body_map["path"] = @msgpack.string(path)
  body_map["headers"] = headers_to_msgpack(headers)
  body_map["body"] = @msgpack.binary(body)
  body_map["stream_mode"] = @msgpack.string("frame_v1")
  let config = get_config()
  let is_encrypted = config.is_encrypt()
  let msg = Message::new(
    kind="http_proxy",
    source_id=get_config().id,
    relay=1,
    version=app_state.version,
    body=@msgpack.map(body_map),
    encrypted=is_encrypted,
    timeout_ms=timeout_ms_uint,
  )
  let msg = { ..msg, target_id: Some(peer_id), payload: Some(req_id) }
  if !send_message_now(peer_id, msg) {
    add_pending_message(msg)
  }
  let start = @env.now()
  let mut last_log = start
  let mut response_sent = false
  let mut logged_first = false
  let mut resp_headers : Map[String, String] = {}
  let mut status_code = 200
  let mut last_chunk_time = start
  let mut total_bytes = 0
  for ;; {
    let now = @env.now()
    if now - start > timeout_ms_u64 {
      if !response_sent {
        conn
        ..send_response(504, "Gateway Timeout", extra_headers={})
        ..write("Timeout fetching object from peer")
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
        last_chunk_time = @env.now()
        if !logged_first {
          log_info("http_proxy_stream first_chunk peer=\{peer_id} path=\{path}")
          log_bench(
            "proxy_stream_first_chunk",
            details="req=\{req_id} peer=\{peer_id} path=\{path}",
          )
          logged_first = true
        }
        if !response_sent {
          match headers_opt {
            Some(h) => resp_headers = h
            None => resp_headers = {}
          }
          status_code = match resp_headers.get("status") {
            Some(s) => @strconv.parse_int(s) catch { _ => 200 }
            None => 200
          }
          resp_headers.remove("status")
          if !resp_headers.contains("Content-Type") {
            resp_headers["Content-Type"] = "application/octet-stream"
          }
          match filename {
            Some(fname) =>
              if !resp_headers.contains("Content-Disposition") {
                resp_headers["Content-Disposition"] = "attachment; filename=\"\{fname}\""
              }
            None => ()
          }
          conn.send_response(
            status_code,
            status_text(status_code),
            extra_headers=resp_headers,
          )
          response_sent = true
        }
        if chunk.length() > 0 {
          total_bytes = total_bytes + chunk.length()
          conn.write(chunk)
        }
        if done {
          log_bench(
            "proxy_stream_done",
            details="req=\{req_id} peer=\{peer_id} path=\{path} bytes=\{total_bytes}",
          )
          conn.end_response()
          return
        }
      }
      None => {
        let now = @env.now()
        if now - last_log > 2000UL {
          log_debug("http_proxy_stream waiting peer=\{peer_id} path=\{path}")
          last_log = now
        }
        if !response_sent && now - last_chunk_time > 5000UL {
          log_warn(
            "http_proxy_stream: no response for 5s, retrying request... peer=\{peer_id}",
          )
          add_pending_message(msg)
          last_chunk_time = now
        }
      }
    }
  }
}

///|
enum ResponseBody {
  Bytes(Bytes)
  File(String)
}

///|
async fn handle_internal_http_request(
  http_method : String,
  path : String,
  headers : Map[String, String],
  body : Bytes,
) -> (Int, Map[String, String], ResponseBody) {
  if http_method == "GET" &&
    @url.Url::parse("http://localhost" + path)
    is Some({ path: Segments(["api", "object", id]), query, .. }) {
    let mut filename = None
    if query is Some(query) {
      let parts = query.split("&")
      for part in parts {
        let part_str = part.to_string()
        if part_str.has_prefix("filename=") {
          filename = Some(part_str[9:].to_string())
        }
      }
    }
    match get_object_path(id) {
      Some(path) => {
        log_info(
          "HTTP: Serving object \{id} via zero-copy file stream: \{path}",
        )
        let resp_headers : Map[String, String] = {
          "Content-Type": "application/octet-stream",
          "Accept-Ranges": "bytes",
        }
        match filename {
          Some(fname) =>
            resp_headers["Content-Disposition"] = "attachment; filename=\"\{fname}\""
          None => ()
        }
        (200, resp_headers, ResponseBody::File(path))
      }
      None =>
        match get_object(id) {
          Some(data) => {
            let (status_code, resp_headers, body) = build_object_download_response(
              data, filename, headers,
            )
            (status_code, resp_headers, ResponseBody::Bytes(body))
          }
          None => {
            let resp_headers : Map[String, String] = {}
            (
              404,
              resp_headers,
              ResponseBody::Bytes(@utf8.encode("Object not found")),
            )
          }
        }
    }
  } else if http_method == "POST" && path == "/api/object" {
    let id = @nanoid.nanoid().unwrap_or(@env.now().to_string())
    save_object(id, body)
    let m = Map::new()
    m["id"] = id.to_json()
    let json_str = m.to_json().stringify()
    let resp_headers : Map[String, String] = {
      "Content-Type": "application/json",
    }
    (200, resp_headers, ResponseBody::Bytes(@utf8.encode(json_str)))
  } else if http_method == "POST" && path == "/api/object/register" {
    let json_str = @utf8.decode(body)
    let json_val = @json.parse(json_str) catch {
      _ => {
        let resp_headers : Map[String, String] = {}
        return (
          400,
          resp_headers,
          ResponseBody::Bytes(@utf8.encode("Bad Request")),
        )
      }
    }
    let path = match json_val {
      Object({ "path": String(s), .. }) => s
      _ => ""
    }
    if path == "" {
      let resp_headers : Map[String, String] = {}
      return (
        400,
        resp_headers,
        ResponseBody::Bytes(@utf8.encode("Missing path")),
      )
    }
    let id = register_object(path)
    let m = Map::new()
    m["id"] = id.to_json()
    let resp_json = m.to_json().stringify()
    let resp_headers : Map[String, String] = {
      "Content-Type": "application/json",
    }
    (200, resp_headers, ResponseBody::Bytes(@utf8.encode(resp_json)))
  } else if http_method == "POST" && path == "/object" {
    let body_str = @utf8.decode(body).trim().to_string()
    if body_str == "" {
      let resp_headers : Map[String, String] = {}
      (
        400,
        resp_headers,
        ResponseBody::Bytes(@utf8.encode("Missing file path")),
      )
    } else {
      let id = register_object(body_str)
      let m = Map::new()
      m["id"] = id.to_json()
      let resp_json = m.to_json().stringify()
      let resp_headers : Map[String, String] = {
        "Content-Type": "application/json",
      }
      (200, resp_headers, ResponseBody::Bytes(@utf8.encode(resp_json)))
    }
  } else if http_method == "GET" && path == "/api/config" {
    let config = get_config()
    let resp_headers : Map[String, String] = {
      "Content-Type": "application/json",
    }
    (
      200,
      resp_headers,
      ResponseBody::Bytes(@utf8.encode(config.to_json().stringify())),
    )
  } else if http_method == "GET" &&
    @url.Url::parse("http://localhost" + path)
    is Some({ path: Segments(["api", "chat", "messages"]), query, .. }) {
    let (peer_id, limit, before) = parse_chat_query(query)
    let resp_headers : Map[String, String] = {
      "Content-Type": "application/json",
    }
    (
      200,
      resp_headers,
      ResponseBody::Bytes(
        @utf8.encode(
          list_chat_messages_page_json(peer_id, limit, before).stringify(),
        ),
      ),
    )
  } else if http_method == "GET" &&
    @url.Url::parse("http://localhost" + path)
    is Some(
      {
        path: Segments(["api", "chat", "messages", "openclaw", "local"]),
        query,
        ..,
      }
    ) {
    let (peer_id, limit, before) = parse_chat_query(query)
    let requester_id = query_param(query, "requester_id").unwrap_or(
      get_config().id,
    )
    let resp_headers : Map[String, String] = {
      "Content-Type": "application/json",
    }
    (
      200,
      resp_headers,
      ResponseBody::Bytes(
        @utf8.encode(
          load_openclaw_session_messages_json(
            peer_id, requester_id, limit, before,
          ).stringify(),
        ),
      ),
    )
  } else if http_method == "POST" && path == "/api/channels/chat/local" {
    let body_str = @utf8.decode(body)
    match parse_channel_chat_request(body_str) {
      Some((_, channel_id, channel_type, messages, session_key, stream)) => {
        let (status_code, response_body) = local_channel_chat_request(
          channel_id, channel_type, messages, session_key, stream,
        )
        (
          status_code,
          { "Content-Type": "application/json" },
          ResponseBody::Bytes(@utf8.encode(response_body.stringify())),
        )
      }
      None =>
        (
          400,
          { "Content-Type": "application/json" },
          ResponseBody::Bytes(
            @utf8.encode(
              { "error": "invalid_channel_chat_request" }.to_json().stringify(),
            ),
          ),
        )
    }
  } else if http_method == "POST" && path == "/api/openclaw/chat/local" {
    let body_str = @utf8.decode(body)
    match parse_channel_chat_request(body_str) {
      Some((_, channel_id, _, messages, session_key, stream)) => {
        let (status_code, response_body) = local_channel_chat_request(
          channel_id, "openclaw", messages, session_key, stream,
        )
        (
          status_code,
          { "Content-Type": "application/json" },
          ResponseBody::Bytes(@utf8.encode(response_body.stringify())),
        )
      }
      None =>
        (
          400,
          { "Content-Type": "application/json" },
          ResponseBody::Bytes(
            @utf8.encode(
              { "error": "invalid_channel_chat_request" }.to_json().stringify(),
            ),
          ),
        )
    }
  } else {
    let resp_headers : Map[String, String] = {}
    (404, resp_headers, ResponseBody::Bytes(@utf8.encode("Not Found")))
  }
}
