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
  let my_id = get_config().id
  let transports = preferred_message_transports()

  for transport in transports {
    let protocol = transport.protocol()
    for target_addr in message_route_candidates(peer_id, protocol) {
      if send_message(transport, target_addr, msg) {
        return (true, Some(protocol), Some(target_addr))
      }
    }
    if relay_message_with_route(transport, my_id, msg, peer_id)
      is (true, Some(route_addr)) {
      return (true, Some(protocol), Some(route_addr))
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
  let body_map : Map[String, @msgpack.Value] = Map([], capacity=0)
  body_map["method"] = @msgpack.string(http_method)
  body_map["path"] = @msgpack.string(path)
  body_map["headers"] = headers_to_msgpack(headers)
  body_map["body"] = @msgpack.binary(body)
  let config = get_config()
  let is_encrypted = config.is_encrypt()
  let msg = Message(
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
        Some(s) => @string.parse_int(s) catch { _ => 200 }
        None => 200
      }
      headers.remove("status")
      Some((status_code, headers, data))
    }
    None => None
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
        let part_str = part.to_owned()
        if part_str.has_prefix("filename=") {
          filename = Some(part_str[9:].to_owned())
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
    let m : Map[String, Json] = {}
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
    let m : Map[String, Json] = {}
    m["id"] = id.to_json()
    let resp_json = m.to_json().stringify()
    let resp_headers : Map[String, String] = {
      "Content-Type": "application/json",
    }
    (200, resp_headers, ResponseBody::Bytes(@utf8.encode(resp_json)))
  } else if http_method == "POST" && path == "/object" {
    let body_str = @utf8.decode(body).trim().to_owned()
    if body_str == "" {
      let resp_headers : Map[String, String] = {}
      (
        400,
        resp_headers,
        ResponseBody::Bytes(@utf8.encode("Missing file path")),
      )
    } else {
      let id = register_object(body_str)
      let m : Map[String, Json] = {}
      m["id"] = id.to_json()
      let resp_json = m.to_json().stringify()
      let resp_headers : Map[String, String] = {
        "Content-Type": "application/json",
      }
      (200, resp_headers, ResponseBody::Bytes(@utf8.encode(resp_json)))
    }
  } else if http_method == "GET" && path == "/api/config" {
    let resp_headers : Map[String, String] = {
      "Content-Type": "application/json",
    }
    (
      200,
      resp_headers,
      ResponseBody::Bytes(@utf8.encode(get_config_response_json().stringify())),
    )
  } else if http_method == "POST" && path == "/api/config/hot-reload" {
    let body_str = @utf8.decode(body)
    match apply_hot_reload_request(body_str) {
      Ok(_) => {
        let resp_headers : Map[String, String] = {
          "Content-Type": "application/json",
        }
        (
          200,
          resp_headers,
          ResponseBody::Bytes(
            @utf8.encode(get_config_response_json().stringify()),
          ),
        )
      }
      Err(err) => {
        let resp_headers : Map[String, String] = {
          "Content-Type": "application/json",
        }
        (
          400,
          resp_headers,
          ResponseBody::Bytes(
            @utf8.encode({ "error": err }.to_json().stringify()),
          ),
        )
      }
    }
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
  } else {
    let resp_headers : Map[String, String] = {}
    (404, resp_headers, ResponseBody::Bytes(@utf8.encode("Not Found")))
  }
}
