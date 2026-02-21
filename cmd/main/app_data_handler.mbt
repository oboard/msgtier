///|
let processed_messages_cache : Ref[Map[String, UInt64]] = Ref::new({})

///|
let response_chunk_size : Int = 65536

///|
struct ResponseChunkState {
  total : Int
  mut received : Int
  chunks : Array[Bytes?]
  mut status : String?
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
) -> (Int, Int, Bytes, String?)? {
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
  if index < 0 || total <= 0 || index >= total || data.length() == 0 {
    None
  } else {
    Some((index, total, data, status))
  }
}

///|
fn store_response_chunk(
  request_id : String,
  index : Int,
  total : Int,
  data : Bytes,
  status : String?,
) -> (Bytes, String?)? {
  let cache = pending_response_chunks.val
  let state = match cache.get(request_id) {
    Some(existing) =>
      if existing.total != total {
        let chunks = Array::make(total, None)
        let s = ResponseChunkState::{ total, received: 0, chunks, status }
        cache[request_id] = s
        s
      } else {
        existing
      }
    None => {
      let chunks = Array::make(total, None)
      let s = ResponseChunkState::{ total, received: 0, chunks, status }
      cache[request_id] = s
      s
    }
  }
  match status {
    Some(s) => if state.status is None { state.status = Some(s) }
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
    cache.remove(request_id)
    Some((Bytes::from_array(arr), status))
  }
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
fn register_app_handlers(dispatcher : MessageDispatcher) -> Unit {
  dispatcher.register("script", handle_script_plugin)
  dispatcher.register("object_get", handle_object_get_message)
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
  let send_chunked = fn(data : Bytes, status : String?) {
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
      send_one(@msgpack.map(m))
    }
  }
  match response_data {
    Binary(b) =>
      if b.length() > response_chunk_size {
        send_chunked(b, None)
      } else {
        send_one(response_data)
      }
    Map(m) => {
      let status = match m.get("status") {
        Some(String(s)) => Some(s)
        _ => None
      }
      let data = match m.get("data") {
        Some(Binary(b)) => Some(b)
        _ => None
      }
      match (status, data) {
        (Some(status), Some(data)) =>
          if data.length() > response_chunk_size {
            send_chunked(data, Some(status))
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
) -> Unit {
  let is_encrypted = get_shared_secret(target_id) is Some(_)
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
  let send_chunked = async fn(data : Bytes, status : String?) {
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
      send_one(@msgpack.map(m))
    }
  }
  match response_data {
    Binary(b) =>
      if b.length() > response_chunk_size {
        send_chunked(b, None)
      } else {
        send_one(response_data)
      }
    Map(m) => {
      let status = match m.get("status") {
        Some(String(s)) => Some(s)
        _ => None
      }
      let data = match m.get("data") {
        Some(Binary(b)) => Some(b)
        _ => None
      }
      match (status, data) {
        (Some(status), Some(data)) =>
          if data.length() > response_chunk_size {
            send_chunked(data, Some(status))
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
        Some((index, total, data, status)) =>
          match
            store_response_chunk(correlation_id, index, total, data, status) {
            Some((full_data, status)) => {
              let headers = match status {
                Some(s) => { "status": s }
                None => {}
              }
              resolve_request(correlation_id, headers, full_data)
            }
            None => ()
          }
        None => {
          let status = match m.get("status") {
            Some(String(s)) => Some(s)
            _ => None
          }
          let data = match m.get("data") {
            Some(Binary(b)) => Some(b)
            _ => None
          }
          match (status, data) {
            (Some(status), Some(data)) =>
              resolve_request(correlation_id, { "status": status }, data)
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
