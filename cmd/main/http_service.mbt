///|
const PAGE_404 : Bytes = b"<html><head></head><body>Page Not Found</body></html>"

///|
struct WsClient {
  conn : @websocket.Conn
  sending : Ref[Bool]
}

///|
let ws_clients : Ref[Map[String, WsClient]] = Ref::new({})

///|

///|

///|
let last_emitted_ids : Ref[Map[String, UInt64]] = Ref::new({})

///|
let last_emitted_order : Ref[Array[String]] = Ref::new([])

///|
async fn emit_ws_message(msg : Message) -> Unit {
  if msg.kind != "text" &&
    msg.kind != "file" &&
    msg.kind != "image" &&
    msg.kind != "video" {
    return
  }

  // Deduplicate messages within a short window
  let now = @env.now()
  let id = msg.id
  match last_emitted_ids.val.get(id) {
    Some(ts) =>
      if now - ts < 10000UL {
        // Already emitted recently
        return
      }
    None => ()
  }

  // Update or insert timestamp
  last_emitted_ids.val[id] = now

  // Track order for FIFO eviction
  last_emitted_order.val.push(id)

  // Cleanup old IDs to maintain max size (FIFO)
  while last_emitted_order.val.length() > 1000 {
    let old_id = last_emitted_order.val[0]
    last_emitted_order.val.remove(0) |> ignore
    last_emitted_ids.val.remove(old_id)
  }

  let m : Json = {
    "id": msg.id,
    "kind": msg.kind,
    "source_id": msg.source_id,
    "target_id": msg.target_id.unwrap_or("broadcast"),
    "timestamp": msg.timestamp.to_double(),
    "content": msg.body.to_json(),
  }

  let json_str = m.stringify()
  let to_remove = []
  // Snapshot clients to avoid concurrent modification issues during async loop
  let clients = []
  for client_id, client in ws_clients.val {
    clients.push((client_id, client))
  }
  for pair in clients {
    let (client_id, client) = pair
    // Spinlock to prevent concurrent writes
    while client.sending.val {
      @async.sleep(1)
    }
    client.sending.val = true
    try {
      client.conn.send_text(json_str)
      client.sending.val = false
    } catch {
      _ => {
        client.sending.val = false
        to_remove.push(client_id)
      }
    }
  }
  for client_id in to_remove {
    ws_clients.val.remove(client_id)
  }
}

///|
fn handle_ws_incoming(text : String) -> String? {
  let json_val = @json.parse(text) catch {
    _ => {
      log_warn("WS: invalid json payload")
      return None
    }
  }

  match json_val {
    Object(m) => {
      let target_val = m.get("target")
      let kind_val = m.get("kind")
      let content_val = m.get("content")

      let target_id_opt = match target_val {
        Some(String(t)) => if t == "broadcast" { None } else { Some(t) }
        _ => None
      }

      let kind = match kind_val {
        Some(String(k)) => k
        _ => "text"
      }

      if kind == "ping" || kind == "pong" || kind == "sync" {
        return Some(kind)
      }

      let body = match (kind, content_val) {
        ("text", Some(String(s))) => @msgpack.string(s)
        ("file", Some(Object(fields))) | ("image", Some(Object(fields))) => {
          let mp_map : Map[String, @msgpack.Value] = Map::new()
          for k, v in fields {
            let mp_val = match v {
              String(s) => @msgpack.string(s)
              Number(n, ..) => @msgpack.int64(n.to_int64())
              _ => @msgpack.nil()
            }
            mp_map[k] = mp_val
          }
          @msgpack.map(mp_map)
        }
        _ => @msgpack.nil()
      }

      let config = get_config()
      let my_id = config.id

      let msg = Message::new(
        kind~,
        source_id=my_id,
        target_id?=target_id_opt,
        body~,
        relay=1,
        version=VERSION,
        timeout_ms=30000,
      )

      let target_display = target_id_opt.unwrap_or("broadcast")
      log_info(
        "WS: Received chat message kind=\{kind} target=\{target_display}",
      )
      add_pending_message(msg)
      Some(kind)
    }
    _ => {
      log_warn("WS: invalid payload format (expected Object)")
      None
    }
  }
}

///|
async fn handle_ws_connection(
  request : @http.Request,
  conn : @http.ServerConnection,
) -> Unit {
  let client_addr = conn.client_addr().to_string()
  try {
    let ws = @websocket.from_http_server(request, conn)
    ws_clients.val[client_addr] = WsClient::{
      conn: ws,
      sending: Ref::new(false),
    }
    defer {
      ws.close()
      ws_clients.val.remove(client_addr)
    }
    for {
      let msg = ws.recv()
      match msg.kind {
        Text => {
          let text = msg.read_all().text()
          if text != "" {
            match handle_ws_incoming(text) {
              Some(kind) =>
                if kind == "ping" {
                  ws.send_text("{\"kind\":\"pong\"}") catch {
                    _ => ()
                  }
                }
              None => ()
            }
          }
        }
        Binary => {
          // Fallback for binary messages (e.g. legacy or other clients)
          let bytes = msg.read_all().binary()
          let content = @utf8.decode(bytes)
          if content != "" {
            match handle_ws_incoming(content) {
              Some(kind) =>
                if kind == "ping" {
                  ws.send_text("{\"kind\":\"pong\"}") catch {
                    _ => ()
                  }
                }
              None => ()
            }
          }
        }
      }
    }
  } catch {
    _ => ()
  }
}

///|
async fn handle_object_upload(
  _request : @http.Request,
  body : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  let bytes = body.read_all().binary()
  let id = @uuidm.v4().to_string_simple()
  save_object(id, bytes)

  let m = Map::new()
  m["id"] = id.to_json()
  let json_str = m.to_json().stringify()

  conn
  ..send_response(200, "OK", extra_headers={
    "Content-Type": "application/json",
  })
  ..write(json_str)
  .end_response()
}

///|
async fn handle_object_registration(
  body : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  let bytes = body.read_all().binary()
  let json_str = @utf8.decode(bytes)
  let json_val = @json.parse(json_str) catch {
    _ => {
      conn.send_response(400, "Bad Request")
      return
    }
  }

  let path = match json_val {
    Object({ "path": String(s), .. }) => s
    _ => ""
  }

  if path == "" {
    conn.send_response(400, "Missing path")
    return
  }

  let id = register_object(path)

  let m = Map::new()
  m["id"] = id.to_json()
  let resp_json = m.to_json().stringify()

  conn
  ..send_response(200, "OK", extra_headers={
    "Content-Type": "application/json",
  })
  ..write(resp_json)
  .end_response()
}

///|
fn parse_range_header(
  headers : Map[String, String],
  total_len : Int,
) -> (Int, Int)? {
  let range = match headers.get("Range") {
    Some(v) => Some(v)
    None => headers.get("range")
  }
  match range {
    Some(r) =>
      if !r.has_prefix("bytes=") || r.length() <= 6 {
        None
      } else {
        let spec = r.replace(old="bytes=", new="")
        let parts = []
        for part in spec.split("-") {
          parts.push(part.to_string())
        }
        if parts.length() != 2 {
          None
        } else {
          let start_str = parts[0]
          let end_str = parts[1]
          let start_opt = parse_decimal_opt(start_str)
          let end_opt = parse_decimal_opt(end_str)
          match (start_opt, end_opt) {
            (Some(start), Some(end)) =>
              if start < 0 {
                None
              } else {
                let start = if start >= total_len { total_len } else { start }
                let end = if end < start { start } else { end }
                let end = if end >= total_len { total_len - 1 } else { end }
                if start >= total_len {
                  None
                } else {
                  Some((start, end))
                }
              }
            (Some(start), None) =>
              if start < 0 || start >= total_len {
                None
              } else {
                Some((start, total_len - 1))
              }
            (None, Some(suffix_len)) =>
              if suffix_len <= 0 || suffix_len > total_len {
                None
              } else {
                Some((total_len - suffix_len, total_len - 1))
              }
            _ => None
          }
        }
      }
    None => None
  }
}

///|
fn parse_decimal_opt(s : String) -> Int? {
  if s == "" {
    return None
  }
  let mut result = 0
  for c in s {
    if c < '0' || c > '9' {
      return None
    }
    result = result * 10 + (c.to_int() - '0'.to_int())
  }
  Some(result)
}

///|
fn parse_decimal_int(s : String, default : Int) -> Int {
  match parse_decimal_opt(s) {
    Some(v) => v
    None => default
  }
}

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
fn build_object_download_response(
  data : Bytes,
  filename : String?,
  request_headers : Map[String, String],
) -> (Int, Map[String, String], Bytes) {
  let headers : Map[String, String] = {
    "Content-Type": "application/octet-stream",
  }
  headers["Accept-Ranges"] = "bytes"
  match filename {
    Some(fname) =>
      headers["Content-Disposition"] = "attachment; filename=\"\{fname}\""
    None => ()
  }
  match parse_range_header(request_headers, data.length()) {
    Some((start, end)) => {
      let end_exclusive = end + 1
      let body = slice_bytes(data, start, end_exclusive)
      headers["Content-Length"] = body.length().to_string()
      headers["Content-Range"] = "bytes \{start}-\{end}/\{data.length()}"
      (206, headers, body)
    }
    None => {
      headers["Content-Length"] = data.length().to_string()
      (200, headers, data)
    }
  }
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
  let req_id = @uuidm.v4().to_string()
  add_pending_request(req_id)
  let body_map : Map[String, @msgpack.Value] = Map::new()
  body_map["method"] = @msgpack.string(http_method)
  body_map["path"] = @msgpack.string(path)
  body_map["headers"] = headers_to_msgpack(headers)
  body_map["body"] = @msgpack.binary(body)
  let is_encrypted = get_shared_secret(peer_id) is Some(_)
  let msg = Message::new(
    kind="http_proxy",
    source_id=get_config().id,
    relay=1,
    version=VERSION,
    body=@msgpack.map(body_map),
    encrypted=is_encrypted,
    timeout_ms=timeout_ms_uint,
  )
  let msg = { ..msg, target_id: Some(peer_id), payload: Some(req_id) }
  add_pending_message(msg)

  match wait_for_response(req_id, timeout_ms_uint) {
    Some((data, headers)) => {
      let status_code = match headers.get("status") {
        Some(s) => parse_decimal_int(s, 200)
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
  let req_id = @uuidm.v4().to_string()
  add_stream_request(req_id)
  let body_map : Map[String, @msgpack.Value] = Map::new()
  body_map["method"] = @msgpack.string(http_method)
  body_map["path"] = @msgpack.string(path)
  body_map["headers"] = headers_to_msgpack(headers)
  body_map["body"] = @msgpack.binary(body)
  let is_encrypted = get_shared_secret(peer_id) is Some(_)
  let msg = Message::new(
    kind="http_proxy",
    source_id=get_config().id,
    relay=1,
    version=VERSION,
    body=@msgpack.map(body_map),
    encrypted=is_encrypted,
    timeout_ms=timeout_ms_uint,
  )
  let msg = { ..msg, target_id: Some(peer_id), payload: Some(req_id) }
  add_pending_message(msg)
  let start = @env.now()
  let mut last_log = start
  let mut response_sent = false
  let mut logged_first = false
  let mut resp_headers : Map[String, String] = {}
  let mut status_code = 200
  for {
    if @env.now() - start > timeout_ms_u64 {
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
    match take_stream_chunk(req_id) {
      Some((chunk, done, headers_opt)) => {
        if !logged_first {
          log_info("http_proxy_stream first_chunk peer=\{peer_id} path=\{path}")
          logged_first = true
        }
        if !response_sent {
          match headers_opt {
            Some(h) => resp_headers = h
            None => resp_headers = {}
          }
          status_code = match resp_headers.get("status") {
            Some(s) => parse_decimal_int(s, 200)
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
          conn.write(chunk)
        }
        if done {
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
        @async.sleep(5)
      }
    }
  }
}

///|
async fn handle_internal_http_request(
  http_method : String,
  path : String,
  headers : Map[String, String],
  body : Bytes,
) -> (Int, Map[String, String], Bytes) {
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
    match get_object(id) {
      Some(data) => build_object_download_response(data, filename, headers)
      None => {
        let resp_headers : Map[String, String] = {}
        (404, resp_headers, @utf8.encode("Object not found"))
      }
    }
  } else if http_method == "POST" && path == "/api/object" {
    let id = @uuidm.v4().to_string_simple()
    save_object(id, body)
    let m = Map::new()
    m["id"] = id.to_json()
    let json_str = m.to_json().stringify()
    let resp_headers : Map[String, String] = {
      "Content-Type": "application/json",
    }
    (200, resp_headers, @utf8.encode(json_str))
  } else if http_method == "POST" && path == "/api/object/register" {
    let json_str = @utf8.decode(body)
    let json_val = @json.parse(json_str) catch {
      _ => {
        let resp_headers : Map[String, String] = {}
        return (400, resp_headers, @utf8.encode("Bad Request"))
      }
    }
    let path = match json_val {
      Object({ "path": String(s), .. }) => s
      _ => ""
    }
    if path == "" {
      let resp_headers : Map[String, String] = {}
      return (400, resp_headers, @utf8.encode("Missing path"))
    }
    let id = register_object(path)
    let m = Map::new()
    m["id"] = id.to_json()
    let resp_json = m.to_json().stringify()
    let resp_headers : Map[String, String] = {
      "Content-Type": "application/json",
    }
    (200, resp_headers, @utf8.encode(resp_json))
  } else if http_method == "GET" && path == "/api/config" {
    let config = get_config()
    let resp_headers : Map[String, String] = {
      "Content-Type": "application/json",
    }
    (200, resp_headers, @utf8.encode(config.to_json().stringify()))
  } else {
    let resp_headers : Map[String, String] = {}
    (404, resp_headers, @utf8.encode("Not Found"))
  }
}

///|
async fn handle_object_download(
  id : String,
  peer_id : String?,
  filename : String?,
  request_headers : Map[String, String],
  conn : @http.ServerConnection,
) -> Unit {
  let has_range = match request_headers.get("Range") {
    Some(_) => true
    None =>
      match request_headers.get("range") {
        Some(_) => true
        None => false
      }
  }
  match get_object_path(id) {
    Some(path) =>
      if !has_range {
        try {
          let file = @fs.open(path, mode=ReadOnly)
          defer file.close()
          let headers : Map[String, String] = {
            "Content-Type": "application/octet-stream",
            "Accept-Ranges": "bytes",
          }
          match filename {
            Some(fname) =>
              headers["Content-Disposition"] = "attachment; filename=\"\{fname}\""
            None => ()
          }
          conn
          ..send_response(200, "OK", extra_headers=headers)
          ..write_reader(file)
          .end_response()
          return
        } catch {
          _ => ()
        }
      }
    None => ()
  }
  match get_object(id) {
    Some(data) => {
      let (status_code, headers, body) = build_object_download_response(
        data, filename, request_headers,
      )
      conn
      ..send_response(
        status_code,
        status_text(status_code),
        extra_headers=headers,
      )
      ..write(body)
      .end_response()
    }
    None =>
      match peer_id {
        Some(pid) => {
          log_info("ObjectStore: fetching object id=\{id} from peer=\{pid}")

          let mut path = "/api/object/" + id
          match filename {
            Some(fname) => path = path + "?filename=" + fname
            None => ()
          }
          let forward_headers : Map[String, String] = {}
          match request_headers.get("Range") {
            Some(v) => forward_headers["Range"] = v
            None =>
              match request_headers.get("range") {
                Some(v) => forward_headers["Range"] = v
                None => ()
              }
          }
          let timeout_ms = 60000
          proxy_http_request_stream(
            pid, "GET", path, forward_headers, b"", timeout_ms, filename, conn,
          )
          return
        }
        None =>
          conn
          ..send_response(404, "Not Found", extra_headers={})
          ..write("Object not found")
          .end_response()
      }
  }
}

///|
async fn handle_http_request(
  request : @http.Request,
  body : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  if request is { meth: Post, path: "/api/object", .. } {
    handle_object_upload(request, body, conn)
    return
  }
  if request is { meth: Post, path: "/api/object/register", .. } {
    handle_object_registration(body, conn)
    return
  }

  if request is { meth: Get, path, .. } &&
    @url.Url::parse("http://localhost" + path)
    is Some({ path: Segments(["api", "object", id]), query, .. }) {
    let mut peer_id = None
    let mut filename = None
    if query is Some(query) {
      let parts = query.split("&")
      for part in parts {
        let part_str = part.to_string()
        if part_str.has_prefix("peer=") {
          peer_id = Some(part_str[5:].to_string())
        } else if part_str.has_prefix("filename=") {
          filename = Some(part_str[9:].to_string())
        }
      }
    }

    handle_object_download(id, peer_id, filename, request.headers, conn)
    return
  }

  if request is { path, .. } &&
    @url.Url::parse("http://localhost" + path)
    is Some({ path: Segments(["api", "proxy"]), query, .. }) {
    let mut peer_id = None
    let mut proxy_path = None
    if query is Some(query) {
      let parts = query.split("&")
      for part in parts {
        let part_str = part.to_string()
        if part_str.has_prefix("peer=") {
          peer_id = Some(part_str[5:].to_string())
        } else if part_str.has_prefix("path=") {
          proxy_path = Some(part_str[5:].to_string())
        }
      }
    }
    if peer_id is None {
      peer_id = request.headers.get("target")
    }
    if proxy_path is None {
      proxy_path = request.headers.get("path")
    }
    match (peer_id, proxy_path) {
      (Some(pid), Some(p)) => {
        let timeout_ms_int = match request.headers.get("timeout") {
          Some(t) => parse_decimal_int(t, 60000)
          None => 60000
        }
        let timeout_ms = if timeout_ms_int < 0 { 60000 } else { timeout_ms_int }
        let forward_headers : Map[String, String] = {}
        for k, v in request.headers {
          if k != "target" && k != "path" && k != "peer" {
            forward_headers[k] = v
          }
        }
        let method_ = request.meth.to_string().to_upper()
        let body_bytes = body.read_all().binary()
        match
          proxy_http_request(
            pid, method_, p, forward_headers, body_bytes, timeout_ms,
          ) {
          Some((status_code, resp_headers, resp_body)) => {
            let headers = resp_headers
            if !headers.contains("Content-Length") {
              headers["Content-Length"] = resp_body.length().to_string()
            }
            conn
            ..send_response(
              status_code,
              status_text(status_code),
              extra_headers=headers,
            )
            ..write(resp_body)
            .end_response()
          }
          None =>
            conn
            ..send_response(504, "Gateway Timeout", extra_headers={})
            ..write("Timeout fetching from peer")
            .end_response()
        }
      }
      _ =>
        conn
        ..send_response(400, "Bad Request", extra_headers={})
        ..write("Missing peer or path")
        .end_response()
    }
    return
  }

  match (request.meth, request.path) {
    (Get, "/api/ws") => handle_ws_connection(request, conn)
    (Get, "/api/config") => get_config_handler(conn)
    (Get, "/api/status") => status_handler(conn)
    (Get, "/api/download") => download_handler(conn)
    (Post, "/api/send") => {
      // Extract target from headers
      let target_id = match request.headers.get("target") {
        Some(t) => t
        None => {
          conn
          ..send_response(400, "Bad Request", extra_headers={
            "Content-Type": "application/json",
          })
          ..write({ "error": "Missing target header" }.to_json().stringify())
          .end_response()
          return
        }
      }

      // Extract timeout from headers (default 10000ms)
      let timeout_ms_int = match request.headers.get("timeout") {
        Some(t) => parse_decimal_int(t, 10000)
        None => 10000
      }
      let timeout_ms = if timeout_ms_int < 0 { 10000 } else { timeout_ms_int }
      let timeout_ms_uint = timeout_ms.reinterpret_as_uint()
      let kind = match request.headers.get("kind") {
        Some(k) => k
        None => "script"
      }

      // Read request body (convert from Bytes to String)
      let body_str = body.read_all().text()
      let config = get_config()
      // Get current node ID and local address
      let my_id = config.id
      let addrs = config.listeners
      let local_addr = if addrs.is_empty() { "127.0.0.1:0" } else { addrs[0] }

      // Prepare data payload (encryption handled at send time)
      let is_self = target_id.trim() == my_id
      let data_val = @msgpack.string(body_str)
      let is_encrypted = !is_self

      // Create data message to send with body as data
      let msg = Message::new(
        kind~,
        source_id=my_id,
        relay=1,
        version=VERSION,
        target_id~,
        body=data_val,
        encrypted=is_encrypted,
        timeout_ms=timeout_ms_uint,
      )
      // Set payload as correlation ID for response tracking
      let msg = { ..msg, payload: Some(msg.id) }

      // Print to stdout for debugging
      log_debug("HTTP /send: Queuing message id=\{msg.id} to \{target_id}")
      log_debug("  From: \{my_id}")
      log_debug("  Local: \{local_addr}")
      log_debug("  Kind: \{kind}")
      log_debug("  Data: \{body_str}")
      log_debug("  Self: \{is_self}")
      log_debug("  Encrypted: \{is_encrypted}")
      log_debug("  Timeout: \{timeout_ms}ms")
      log_debug("  DataVal: String len=\{body_str.length()}")
      log_info(
        "HTTP /send: Added pending message id=\{msg.id} target=\{target_id}",
      )

      // Check if target peer exists or is self
      let target_peer = get_global_peer_manager().get_peer(target_id)
      let is_self = target_id == my_id
      match (target_peer, is_self) {
        (Some(_), _) | (None, true) => {

          // Register request to track response
          add_pending_request(msg.id)

          // Add to pending message queue
          add_pending_message(msg)
          log_debug("HTTP /send: Registered request id=\{msg.id}")

          // Wait for response with timeout
          match wait_for_response(msg.id, timeout_ms_uint) {
            Some((response, headers)) =>
              // Ensure Content-Type is set if missing
              conn
              ..send_response(200, "OK", extra_headers=headers)
              ..write(response)
              .end_response()
            None =>
              conn
              ..send_response(504, "Gateway Timeout", extra_headers={
                "Content-Type": "application/json",
              })
              ..write(
                { "error": "Request timed out", "target": target_id }
                .to_json()
                .stringify(),
              )
              .end_response()
          }
        }
        (None, false) =>
          conn
          ..send_response(404, "Not Found", extra_headers={
            "Content-Type": "application/json",
          })
          ..write(
            { "error": "Target peer not found", "target": target_id }
            .to_json()
            .stringify(),
          )
          .end_response()
      }
    }
    (Get, path) => serve_static_handler(conn, path)
    _ => notfound_handler(conn)
  }
}

///|
async fn start_http_service(addr : String) -> Unit {
  // Store the config globally for handlers to access
  init_upload_dir()
  for {
    try {
      let server = @http.Server::new(@socket.Addr::parse(addr), reuse_addr=true)
      server.run_forever(handle_http_request)
    } catch {
      e => {
        log_warn("HTTP server failed to start: \{e}. Retrying in 5 seconds...")
        @async.sleep(5000)
      }
    }
  }
}

///|
async fn serve_static_handler(
  conn : @http.ServerConnection,
  path : String,
) -> Unit {
  let path = if path == "/" { "index.html" } else { path }
  // Basic security check
  if path.contains("..") {
    notfound_handler(conn)
    return
  }
  if @web.dist.get(path[1:]) is Some(bytes) {
    serve_file(conn, bytes, path)
  } else {
    serve_file(conn, @web.dist["index.html"], "index.html")
  }
}

///|
async fn serve_file(
  conn : @http.ServerConnection,
  file : Bytes,
  path : String,
) -> Unit {
  try {
    let content_type = match path {
      _ as p if p.has_suffix(".html") => "text/html"
      _ as p if p.has_suffix(".css") => "text/css"
      _ as p if p.has_suffix(".js") => "text/javascript"
      _ as p if p.has_suffix(".json") => "application/json"
      _ as p if p.has_suffix(".png") => "image/png"
      _ as p if p.has_suffix(".jpg") || p.has_suffix(".jpeg") => "image/jpeg"
      _ as p if p.has_suffix(".svg") => "image/svg+xml"
      _ as p if p.has_suffix(".ico") => "image/x-icon"
      _ => "application/octet-stream"
    }
    conn
    ..send_response(200, "OK", extra_headers={ "Content-Type": content_type })
    ..write(file)
    .end_response()
  } catch {
    _ => ()
  }
}

///|
// async fn serve_file(
//   conn : @http.ServerConnection,
//   file_path : String,
//   path : String,
// ) -> Unit {
//   let file = @fs.open(file_path, mode=ReadOnly) catch {
//     _ => {
//       notfound_handler(conn)
//       return
//     }
//   }
//   defer file.close()
//   try {
//     let content_type = match path {
//       _ as p if p.has_suffix(".html") => "text/html"
//       _ as p if p.has_suffix(".css") => "text/css"
//       _ as p if p.has_suffix(".js") => "text/javascript"
//       _ as p if p.has_suffix(".json") => "application/json"
//       _ as p if p.has_suffix(".png") => "image/png"
//       _ as p if p.has_suffix(".jpg") || p.has_suffix(".jpeg") => "image/jpeg"
//       _ as p if p.has_suffix(".svg") => "image/svg+xml"
//       _ as p if p.has_suffix(".ico") => "image/x-icon"
//       _ => "application/octet-stream"
//     }
//     conn
//     ..send_response(200, "OK", extra_headers={ "Content-Type": content_type })
//     ..write_reader(file)
//     .end_response()
//   } catch {
//     _ => ()
//   }
// }

///|
async fn get_config_handler(conn : @http.ServerConnection) -> Unit {
  let config = get_config()
  // Return the actual configuration, but hide sensitive information
  conn
  ..send_response(200, "OK", extra_headers={
    "Content-Type": "application/json",
  })
  ..write(config.to_json().stringify())
  .end_response()
}

///|
async fn status_handler(conn : @http.ServerConnection) -> Unit {
  let my_config = get_config()
  let my_id = my_config.id
  let raw_peers = get_global_peer_manager().get_all_peers()
  let all_peers = []
  for p in raw_peers {
    if p.id != my_id {
      all_peers.push(p)
    }
  }

  // Add myself to the peers list to show my connections
  let my_pk = get_public_key()
  let my_addrs = my_config.listeners.map(addr => {
    addr.replace(old="0.0.0.0", new="127.0.0.1")
  })

  // Get my active direct connections
  let all_conns = get_global_connection_manager().get_all_connections()
  let my_connections : Array[PeerConnectionInfo] = []
  for conn in all_conns {
    let elapsed_ms = @env.now() - conn.last_seen
    let bandwidth_mbps = conn.calculate_bandwidth_mbps(elapsed_ms)
    let packet_loss_rate = conn.calculate_packet_loss()
    my_connections.push(PeerConnectionInfo::{
      peer_id: conn.peer_id,
      ports: conn.ports,
      latency_ms: conn.latency_ms,
      bandwidth_mbps,
      packet_loss_rate,
      id: conn.id,
      last_seen: conn.last_seen,
      quality: conn.quality,
      relay: conn.relay,
      metadata: conn.metadata,
      latency_history: conn.latency_history,
      packets_sent: conn.packets_sent,
      packets_lost: conn.packets_lost,
      bytes_sent: conn.bytes_sent,
      bytes_received: conn.bytes_received,
      last_ping_time: conn.last_ping_time,
      nat_type: conn.nat_type,
    })
  }
  let me = PeerNode::new(
    id=my_id,
    version=VERSION,
    public_key=my_pk,
    addresses=my_addrs,
    metadata=my_config.metadata.unwrap_or({}),
  )
  let me_with_conns = { ..me, connections: my_connections }
  all_peers.push(me_with_conns)

  // Include routing table info
  let all_routes = get_global_peer_manager().get_all_routes()
  let routes_info : Array[RouteInfo] = []
  for target_id, route in all_routes {
    routes_info.push(RouteInfo::{
      target_peer_id: target_id,
      next_hop: route.next_hop,
      hops: route.hops,
      timestamp: route.timestamp,
    })
  }

  // Build known peers list (from active discovery)
  let known_peers = get_all_known_peers()
  let config = get_config()
  let status_info = StatusInfo::{
    status: "ok",
    peers: all_peers,
    peers_count: all_peers.length(),
    peer_id: config.id,
    listeners: config.listeners,
    known_peers,
    routes: routes_info,
  }
  conn
  ..send_response(200, "OK", extra_headers={
    "Content-Type": "application/json",
  })
  ..write(status_info.to_json().stringify())
  .end_response()
}

///|
async fn notfound_handler(conn : @http.ServerConnection) -> Unit {
  conn
  ..send_response(404, "Not Found", extra_headers={
    "Content-Type": "text/html",
  })
  ..write(PAGE_404)
  .end_response()
}

///|
async fn download_handler(conn : @http.ServerConnection) -> Unit {
  let args = @env.args()
  let exe_path = if args.length() > 0 { args[0] } else { "./msgtier" }
  try {
    let file = @fs.open(exe_path, mode=ReadOnly)
    defer file.close()
    conn
    ..send_response(200, "OK", extra_headers={
      "Content-Type": "application/octet-stream",
      "Content-Disposition": "attachment; filename=\"msgtier\"",
    })
    ..write_reader(file)
    .end_response()
  } catch {
    e =>
      conn
      ..send_response(500, "Internal Server Error", extra_headers={
        "Content-Type": "application/json",
      })
      ..write({ "error": e.to_string() }.to_json().stringify())
      .end_response()
  }
}
