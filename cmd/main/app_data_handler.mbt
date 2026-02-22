///|
let processed_messages_cache : Ref[Map[String, UInt64]] = Ref::new({})

///|
let response_chunk_size : Int = 16777216

///|
let http_proxy_no_encrypt_threshold : Int = 1048576

///|
struct ResponseChunkState {
  total : Int
  mut received : Int
  chunks : Array[Bytes?]
  mut status : String?
  mut headers : Map[String, String]?
}

///|
let pending_response_chunks : Ref[Map[String, ResponseChunkState]] = Ref::new({})

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
fn slice_bytes(b : Bytes, start : Int, end : Int) -> Bytes {
  let len = end - start
  if len <= 0 {
    return b""
  }
  let arr = Array::make(len, b'\x00')
  for i = 0; i < len; i = i + 1 {
    arr[i] = b[start + i]
  }
  Bytes::from_array(arr)
}

///|
fn parse_response_chunk(
  m : Map[String, @msgpack.Value],
) -> (Int, Int, Bytes, String?, Map[String, String]?)? {
  let index = match m.get("chunk_index") {
    Some(Int(i)) => i
    Some(Int64(i)) => i.to_int()
    Some(UInt64(i)) => i.reinterpret_as_int64().to_int()
    _ => -1
  }
  let total = match m.get("chunk_total") {
    Some(Int(i)) => i
    Some(Int64(i)) => i.to_int()
    Some(UInt64(i)) => i.reinterpret_as_int64().to_int()
    _ => -1
  }
  let data = match m.get("chunk_data") {
    Some(Binary(b)) => b
    _ => b""
  }
  let status = match m.get("status") {
    Some(String(s)) => Some(s)
    _ => None
  }
  let headers = parse_headers_map(m)
  if index < 0 || total <= 0 || index >= total || data.length() == 0 {
    None
  } else {
    Some((index, total, data, status, headers))
  }
}

///|
fn store_response_chunk(
  request_id : String,
  index : Int,
  total : Int,
  data : Bytes,
  status : String?,
  headers : Map[String, String]?,
) -> (Bytes, String?, Map[String, String]?)? {
  let cache = pending_response_chunks.val
  let state = match cache.get(request_id) {
    Some(existing) =>
      if existing.total != total {
        let chunks = Array::make(total, None)
        let s = ResponseChunkState::{
          total,
          received: 0,
          chunks,
          status,
          headers,
        }
        cache[request_id] = s
        s
      } else {
        existing
      }
    None => {
      let chunks = Array::make(total, None)
      let s = ResponseChunkState::{
        total,
        received: 0,
        chunks,
        status,
        headers,
      }
      cache[request_id] = s
      s
    }
  }
  match status {
    Some(s) => if state.status is None { state.status = Some(s) }
    None => ()
  }
  match headers {
    Some(h) => if state.headers is None { state.headers = Some(h) }
    None => ()
  }
  match state.chunks[index] {
    Some(_) => ()
    None => {
      state.chunks[index] = Some(data)
      state.received = state.received + 1
    }
  }
  if state.received != state.total {
    None
  } else {
    let mut total_len = 0
    for item in state.chunks {
      match item {
        Some(b) => total_len = total_len + b.length()
        None => ()
      }
    }
    let arr = Array::make(total_len, b'\x00')
    let mut offset = 0
    for item in state.chunks {
      match item {
        Some(b) => {
          for i = 0; i < b.length(); i = i + 1 {
            arr[offset + i] = b[i]
          }
          offset = offset + b.length()
        }
        None => ()
      }
    }
    let status = state.status
    let headers = state.headers
    cache.remove(request_id)
    Some((Bytes::from_array(arr), status, headers))
  }
}

///|
fn parse_headers_map(m : Map[String, @msgpack.Value]) -> Map[String, String]? {
  match m.get("headers") {
    Some(Map(headers_map)) => {
      let headers : Map[String, String] = {}
      for k, v in headers_map {
        match v {
          String(s) => headers[k] = s
          _ => ()
        }
      }
      Some(headers)
    }
    _ => None
  }
}

///|
fn headers_to_msgpack(headers : Map[String, String]) -> @msgpack.Value {
  let m : Map[String, @msgpack.Value] = Map::new()
  for k, v in headers {
    m[k] = @msgpack.string(v)
  }
  @msgpack.map(m)
}

///|
fn ensure_status_header(
  status : String,
  headers : Map[String, String]?,
) -> Map[String, String] {
  let merged = match headers {
    Some(h) => h
    None => {}
  }
  merged["status"] = status
  merged
}

///|
fn handle_script_message(
  root : @async.TaskGroup[Unit],
  id : String,
  local_addr : String,
  msg : Message,
  data_value : @msgpack.Value,
) -> Unit {
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
    let content_str = if data_content is String(content) { content } else { "" }
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
      Some(output) =>
        send_response_message(
          id,
          local_addr,
          msg.source_id,
          msg.payload.unwrap_or(msg.id),
          output.to_msgpack(),
        )
      None =>
        log_warn(
          "Script execution returned no output for message \{msg.id} content='\{content_str}'",
        )
    }
  })
}

///|
fn script_message_plugin() -> MessagePlugin {
  { register: register_script_handlers }
}

///|
fn object_message_plugin() -> MessagePlugin {
  { register: register_object_handlers }
}

///|
fn register_script_handlers(dispatcher : MessageDispatcher) -> Unit {
  dispatcher.register("script", handle_script_plugin)
}

///|
fn register_object_handlers(dispatcher : MessageDispatcher) -> Unit {
  dispatcher.register("object_get", handle_object_get_message)
  dispatcher.register("http_proxy", handle_http_proxy_message)
}

///|
fn handle_script_plugin(ctx : MessageContext) -> Unit {
  handle_script_message(
    ctx.root,
    ctx.my_id,
    ctx.local_addr,
    ctx.msg,
    ctx.msg.body,
  )
}

///|
fn handle_object_get_message(ctx : MessageContext) -> Unit {
  let msg = ctx.msg
  if check_and_mark_processed(msg.id, msg.timestamp) {
    log_warn("Duplicate or expired message \{msg.id} ignored")
    return
  }
  let object_id = match msg.body {
    Map(m) =>
      match m.get("id") {
        Some(String(s)) => s
        _ => ""
      }
    String(s) => s
    _ => ""
  }
  if object_id == "" {
    log_warn("object_get: empty id from \{msg.source_id}")
    return
  }
  ctx.root.spawn_bg(async fn() {
    let data_opt = get_object(object_id) catch { _ => None }
    let resp_map : Map[String, @msgpack.Value] = Map::new()
    match data_opt {
      Some(data) => {
        resp_map["status"] = @msgpack.string("200")
        resp_map["data"] = @msgpack.binary(data)
      }
      None => {
        resp_map["status"] = @msgpack.string("404")
        resp_map["data"] = @msgpack.binary(b"")
      }
    }
    send_response_message_direct(
      ctx.transport,
      ctx.sender_addr,
      ctx.my_id,
      ctx.local_addr,
      msg.source_id,
      msg.payload.unwrap_or(msg.id),
      @msgpack.map(resp_map),
      Some(msg.encrypted),
    )
  })
}

///|
fn handle_http_proxy_message(ctx : MessageContext) -> Unit {
  let msg = ctx.msg
  let should_skip_quic = if ctx.transport.protocol() == "quic" {
    let conns = get_global_connection_manager().get_peer_connections(
      msg.source_id,
    )
    let mut has_non_quic = false
    for conn in conns {
      for p in conn.ports {
        if p.protocol != Protocol::Quic {
          has_non_quic = true
        }
      }
    }
    has_non_quic
  } else {
    false
  }
  if should_skip_quic {
    log_debug("http_proxy: quic received with non-quic peer=\{msg.source_id}")
  }
  if check_and_mark_processed(msg.id, msg.timestamp) {
    log_warn("Duplicate or expired message \{msg.id} ignored")
    return
  }
  let (http_method, path, headers, body) = match msg.body {
    Map(m) => {
      let http_method = match m.get("method") {
        Some(String(s)) => s
        _ => "GET"
      }
      let path = match m.get("path") {
        Some(String(s)) => s
        _ => "/"
      }
      let headers = match m.get("headers") {
        Some(Map(hm)) => {
          let h : Map[String, String] = {}
          for k, v in hm {
            match v {
              String(s) => h[k] = s
              _ => ()
            }
          }
          h
        }
        _ => {}
      }
      let body = match m.get("body") {
        Some(Binary(b)) => b
        _ => b""
      }
      (http_method, path, headers, body)
    }
    _ => ("GET", "/", {}, b"")
  }
  ctx.root.spawn_bg(async fn() {
    let (status_code, resp_headers, resp_body) = handle_internal_http_request(
      http_method, path, headers, body,
    )
    let resp_map : Map[String, @msgpack.Value] = Map::new()
    resp_map["status"] = @msgpack.string(status_code.to_string())
    resp_map["headers"] = headers_to_msgpack(resp_headers)
    resp_map["data"] = @msgpack.binary(resp_body)
    let use_encryption = if resp_body.length() >=
      http_proxy_no_encrypt_threshold {
      false
    } else {
      msg.encrypted
    }
    send_response_message_direct(
      ctx.transport,
      ctx.sender_addr,
      ctx.my_id,
      ctx.local_addr,
      msg.source_id,
      msg.payload.unwrap_or(msg.id),
      @msgpack.map(resp_map),
      Some(use_encryption),
    )
  })
}

///|
fn send_response_message(
  source_id : String,
  source_addr : String,
  target_id : String,
  correlation_id : String,
  response_data : @msgpack.Value,
) -> Unit {
  let is_encrypted = get_shared_secret(target_id) is Some(_)
  let send_one = fn(body : @msgpack.Value) {
    let response_msg = Message::new(
      kind="response",
      source_id~,
      source_addr~,
      target_id~,
      relay=1,
      body~,
      encrypted=is_encrypted,
      payload=correlation_id,
    )
    add_pending_message(response_msg)
  }
  let send_chunked = fn(
    data : Bytes,
    status : String?,
    headers : Map[String, String]?,
  ) {
    let total = (data.length() + response_chunk_size - 1) / response_chunk_size
    for i = 0; i < total; i = i + 1 {
      let start = i * response_chunk_size
      let end = if start + response_chunk_size > data.length() {
        data.length()
      } else {
        start + response_chunk_size
      }
      let chunk = slice_bytes(data, start, end)
      let m : Map[String, @msgpack.Value] = Map::new()
      m["chunk_index"] = @msgpack.int(i)
      m["chunk_total"] = @msgpack.int(total)
      m["chunk_data"] = @msgpack.binary(chunk)
      match status {
        Some(s) => m["status"] = @msgpack.string(s)
        None => ()
      }
      match headers {
        Some(h) => m["headers"] = headers_to_msgpack(h)
        None => ()
      }
      send_one(@msgpack.map(m))
    }
  }
  match response_data {
    Binary(b) =>
      if b.length() > response_chunk_size {
        send_chunked(b, None, None)
      } else {
        send_one(response_data)
      }
    Map(m) => {
      let status = match m.get("status") {
        Some(String(s)) => Some(s)
        _ => None
      }
      let headers = parse_headers_map(m)
      let data = match m.get("data") {
        Some(Binary(b)) => Some(b)
        _ => None
      }
      match (status, data) {
        (Some(status), Some(data)) =>
          if data.length() > response_chunk_size {
            send_chunked(data, Some(status), headers)
          } else {
            send_one(response_data)
          }
        _ => send_one(response_data)
      }
    }
    _ => send_one(response_data)
  }
  log_info(
    "DataResponse: queued correlation=\{correlation_id} to=\{target_id} encrypted=\{is_encrypted}",
  )
}

///|
async fn send_response_message_direct(
  transport : &Transport,
  target_addr : String,
  source_id : String,
  source_addr : String,
  target_id : String,
  correlation_id : String,
  response_data : @msgpack.Value,
  encrypted_override : Bool?,
) -> Unit {
  let is_encrypted = match encrypted_override {
    Some(v) => v
    None => get_shared_secret(target_id) is Some(_)
  }
  let resolved_addr = if target_addr.is_empty() {
    pick_peer_address(target_id, transport.protocol()).unwrap_or(target_addr)
  } else {
    target_addr
  }
  let send_one = async fn(body : @msgpack.Value) {
    let response_msg = Message::new(
      kind="response",
      source_id~,
      source_addr~,
      target_id~,
      relay=1,
      body~,
      encrypted=is_encrypted,
      payload=correlation_id,
    )
    let ok = send_message(transport, resolved_addr, response_msg)
    if !ok {
      add_pending_message(response_msg)
    }
  }
  let send_chunked = async fn(
    data : Bytes,
    status : String?,
    headers : Map[String, String]?,
  ) {
    let total = (data.length() + response_chunk_size - 1) / response_chunk_size
    for i = 0; i < total; i = i + 1 {
      let start = i * response_chunk_size
      let end = if start + response_chunk_size > data.length() {
        data.length()
      } else {
        start + response_chunk_size
      }
      let chunk = slice_bytes(data, start, end)
      let m : Map[String, @msgpack.Value] = Map::new()
      m["chunk_index"] = @msgpack.int(i)
      m["chunk_total"] = @msgpack.int(total)
      m["chunk_data"] = @msgpack.binary(chunk)
      match status {
        Some(s) => m["status"] = @msgpack.string(s)
        None => ()
      }
      match headers {
        Some(h) => m["headers"] = headers_to_msgpack(h)
        None => ()
      }
      send_one(@msgpack.map(m))
    }
  }
  match response_data {
    Binary(b) =>
      if b.length() > response_chunk_size {
        send_chunked(b, None, None)
      } else {
        send_one(response_data)
      }
    Map(m) => {
      let status = match m.get("status") {
        Some(String(s)) => Some(s)
        _ => None
      }
      let headers = parse_headers_map(m)
      let data = match m.get("data") {
        Some(Binary(b)) => Some(b)
        _ => None
      }
      match (status, data) {
        (Some(status), Some(data)) =>
          if data.length() > response_chunk_size {
            send_chunked(data, Some(status), headers)
          } else {
            send_one(response_data)
          }
        _ => send_one(response_data)
      }
    }
    _ => send_one(response_data)
  }
  log_info(
    "DataResponse: direct correlation=\{correlation_id} to=\{target_id} encrypted=\{is_encrypted}",
  )
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
  if is_stream_request(correlation_id) {
    match response_data {
      Binary(b) => push_stream_data(correlation_id, b, None)
      Array(arr) => {
        let strings = []
        for v in arr {
          if v is String(s) {
            strings.push(s)
          }
        }
        push_stream_data(
          correlation_id,
          @utf8.encode(strings.to_json().stringify()),
          None,
        )
      }
      Map(m) =>
        match parse_response_chunk(m) {
          Some((index, total, data, status, headers)) => {
            let merged_headers = match status {
              Some(s) => Some(ensure_status_header(s, headers))
              None => headers
            }
            push_stream_chunk(
              correlation_id, index, total, data, merged_headers,
            )
          }
          None => {
            let status = match m.get("status") {
              Some(String(s)) => Some(s)
              _ => None
            }
            let headers = parse_headers_map(m)
            let data = match m.get("data") {
              Some(Binary(b)) => Some(b)
              _ => None
            }
            match (status, data) {
              (Some(status), Some(data)) => {
                let merged_headers = Some(ensure_status_header(status, headers))
                push_stream_data(correlation_id, data, merged_headers)
              }
              _ => {
                let output = match m.get("output") {
                  Some(String(s)) => s
                  _ => response_data.to_string().unwrap_or("error")
                }
                push_stream_data(correlation_id, @utf8.encode(output), None)
              }
            }
          }
        }
      _ =>
        push_stream_data(
          correlation_id,
          @utf8.encode(response_data.to_string().unwrap_or("error")),
          None,
        )
    }
    return
  }
  match response_data {
    Binary(b) => resolve_request(correlation_id, {}, b)
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
    Map(m) =>
      match parse_response_chunk(m) {
        Some((index, total, data, status, headers)) =>
          match
            store_response_chunk(
              correlation_id, index, total, data, status, headers,
            ) {
            Some((full_data, status, headers)) => {
              let merged_headers = match status {
                Some(s) => ensure_status_header(s, headers)
                None =>
                  match headers {
                    Some(h) => h
                    None => {}
                  }
              }
              resolve_request(correlation_id, merged_headers, full_data)
            }
            None => ()
          }
        None => {
          let status = match m.get("status") {
            Some(String(s)) => Some(s)
            _ => None
          }
          let headers = parse_headers_map(m)
          let data = match m.get("data") {
            Some(Binary(b)) => Some(b)
            _ => None
          }
          match (status, data) {
            (Some(status), Some(data)) => {
              let merged_headers = ensure_status_header(status, headers)
              resolve_request(correlation_id, merged_headers, data)
            }
            _ => {
              let output = match m.get("output") {
                Some(String(s)) => s
                _ => response_data.to_string().unwrap_or("error")
              }
              resolve_request(correlation_id, {}, @utf8.encode(output))
            }
          }
        }
      }
    _ =>
      resolve_request(
        correlation_id,
        {},
        @utf8.encode(response_data.to_string().unwrap_or("error")),
      )
  }
}
