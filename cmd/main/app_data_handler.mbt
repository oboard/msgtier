///|
struct AppDataHandlerState {
  processed_messages_cache : Map[String, UInt64]
  pending_response_chunks : Map[String, ResponseChunkState]
  response_chunk_size : Int
  http_proxy_no_encrypt_threshold : Int
  stream_priority_chunks : Int
  stream_frame_magic : Bytes
  stream_frame_version : Int
}

///|
let app_data_handler_state : AppDataHandlerState = {
  processed_messages_cache: {},
  pending_response_chunks: {},
  response_chunk_size: 1048576,
  http_proxy_no_encrypt_threshold: 1048576,
  stream_priority_chunks: 4,
  stream_frame_magic: b"MSTR",
  stream_frame_version: 1,
}

///|
struct ResponseChunkState {
  total : Int
  mut received : Int
  chunks : Array[Bytes?]
  mut status : String?
  mut headers : Map[String, String]?
}

///|
fn check_and_mark_processed(id : String, timestamp : UInt64) -> Bool {
  let now = @env.now()
  // TTL Check (30s)
  if now > timestamp && now - timestamp > 30000 {
    log_warn("Dropping expired message \{id}, age=\{now - timestamp}ms")
    return true
  }
  let cache = app_data_handler_state.processed_messages_cache
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
  let arr = FixedArray::make(len, b'\x00')
  for i = 0; i < len; i = i + 1 {
    arr[i] = b[start + i]
  }
  Bytes::from_array(arr)
}

///|
fn write_u16(buf : FixedArray[Byte], offset : Int, value : Int) -> Unit {
  buf[offset] = ((value >> 8) & 0xFF).to_byte()
  buf[offset + 1] = (value & 0xFF).to_byte()
}

///|
fn write_u32(buf : FixedArray[Byte], offset : Int, value : Int) -> Unit {
  buf[offset] = ((value >> 24) & 0xFF).to_byte()
  buf[offset + 1] = ((value >> 16) & 0xFF).to_byte()
  buf[offset + 2] = ((value >> 8) & 0xFF).to_byte()
  buf[offset + 3] = (value & 0xFF).to_byte()
}

///|
fn read_u16(buf : Bytes, offset : Int) -> Int? {
  if offset + 2 > buf.length() {
    None
  } else {
    Some((buf[offset].to_int() << 8) | buf[offset + 1].to_int())
  }
}

///|
fn read_u32(buf : Bytes, offset : Int) -> Int? {
  if offset + 4 > buf.length() {
    None
  } else {
    Some(
      (buf[offset].to_int() << 24) |
      (buf[offset + 1].to_int() << 16) |
      (buf[offset + 2].to_int() << 8) |
      buf[offset + 3].to_int(),
    )
  }
}

///|
fn encode_stream_frame(
  correlation_id : String,
  index : Int,
  total : Int,
  data : Bytes,
  headers : Map[String, String]?,
  encrypted : Bool,
) -> Bytes {
  let corr_bytes = @utf8.encode(correlation_id)
  let header_pairs = match headers {
    Some(h) => h
    None => {}
  }
  let key_bytes : Array[Bytes] = []
  let value_bytes : Array[Bytes] = []
  let mut meta_len = 0
  for key, value in header_pairs {
    let kb = @utf8.encode(key)
    let vb = @utf8.encode(value)
    key_bytes.push(kb)
    value_bytes.push(vb)
    meta_len = meta_len + 2 + 4 + kb.length() + vb.length()
  }
  let payload = if encrypted {
    encrypt_with_message_key(correlation_id, data)
  } else {
    data
  }
  let total_len = 24 + corr_bytes.length() + meta_len + payload.length()
  let buf = FixedArray::make(total_len, b'\x00')
  buf[0] = app_data_handler_state.stream_frame_magic[0]
  buf[1] = app_data_handler_state.stream_frame_magic[1]
  buf[2] = app_data_handler_state.stream_frame_magic[2]
  buf[3] = app_data_handler_state.stream_frame_magic[3]
  buf[4] = app_data_handler_state.stream_frame_version.to_byte()
  let flags = if encrypted { 1 } else { 0 }
  buf[5] = flags.to_byte()
  write_u16(buf, 6, header_pairs.length())
  write_u32(buf, 8, index)
  write_u32(buf, 12, total)
  write_u32(buf, 16, corr_bytes.length())
  write_u32(buf, 20, payload.length())
  let mut offset = 24
  for i = 0; i < corr_bytes.length(); i = i + 1 {
    buf[offset + i] = corr_bytes[i]
  }
  offset = offset + corr_bytes.length()
  for i = 0; i < key_bytes.length(); i = i + 1 {
    let kb = key_bytes[i]
    let vb = value_bytes[i]
    write_u16(buf, offset, kb.length())
    offset = offset + 2
    write_u32(buf, offset, vb.length())
    offset = offset + 4
    for j = 0; j < kb.length(); j = j + 1 {
      buf[offset + j] = kb[j]
    }
    offset = offset + kb.length()
    for j = 0; j < vb.length(); j = j + 1 {
      buf[offset + j] = vb[j]
    }
    offset = offset + vb.length()
  }
  for i = 0; i < payload.length(); i = i + 1 {
    buf[offset + i] = payload[i]
  }
  Bytes::from_array(buf)
}

///|
fn decode_stream_frame(
  raw : Bytes,
) -> (String, Int, Int, Bytes, Map[String, String]?, Bool)? {
  if raw.length() < 24 ||
    raw[0] != app_data_handler_state.stream_frame_magic[0] ||
    raw[1] != app_data_handler_state.stream_frame_magic[1] ||
    raw[2] != app_data_handler_state.stream_frame_magic[2] ||
    raw[3] != app_data_handler_state.stream_frame_magic[3] ||
    raw[4].to_int() != app_data_handler_state.stream_frame_version {
    return None
  }
  let flags = raw[5].to_int()
  let encrypted = (flags & 1) != 0
  let meta_count = read_u16(raw, 6).unwrap_or(0)
  let index = read_u32(raw, 8).unwrap_or(-1)
  let total = read_u32(raw, 12).unwrap_or(-1)
  let corr_len = read_u32(raw, 16).unwrap_or(-1)
  let data_len = read_u32(raw, 20).unwrap_or(-1)
  if index < 0 || total <= 0 || index >= total || corr_len < 0 || data_len < 0 {
    return None
  }
  let mut offset = 24
  if offset + corr_len > raw.length() {
    return None
  }
  let correlation_id = @utf8.decode(slice_bytes(raw, offset, offset + corr_len)) catch {
    _ => return None
  }
  offset = offset + corr_len
  let headers : Map[String, String] = {}
  for i = 0; i < meta_count; i = i + 1 {
    let key_len = read_u16(raw, offset).unwrap_or(-1)
    offset = offset + 2
    let value_len = read_u32(raw, offset).unwrap_or(-1)
    offset = offset + 4
    if key_len < 0 ||
      value_len < 0 ||
      offset + key_len + value_len > raw.length() {
      return None
    }
    let key = @utf8.decode(slice_bytes(raw, offset, offset + key_len)) catch {
      _ => return None
    }
    offset = offset + key_len
    let value = @utf8.decode(slice_bytes(raw, offset, offset + value_len)) catch {
      _ => return None
    }
    offset = offset + value_len
    headers[key] = value
  }
  if offset + data_len > raw.length() {
    return None
  }
  let data = slice_bytes(raw, offset, offset + data_len)
  let decoded_data = if encrypted {
    match decrypt_with_message_key(correlation_id, data) {
      Some(decrypted) => decrypted
      None => return None
    }
  } else {
    data
  }
  Some(
    (
      correlation_id,
      index,
      total,
      decoded_data,
      if headers.is_empty() {
        None
      } else {
        Some(headers)
      },
      encrypted,
    ),
  )
}

///|
fn merge_stream_headers(
  status : String?,
  headers : Map[String, String]?,
) -> Map[String, String]? {
  let merged = match headers {
    Some(h) => h
    None => {}
  }
  match status {
    Some(s) => merged["status"] = s
    None => ()
  }
  if merged.is_empty() {
    None
  } else {
    Some(merged)
  }
}

///|
fn try_handle_stream_frame(raw : Bytes) -> Bool {
  match decode_stream_frame(raw) {
    Some((correlation_id, index, total, data, headers, _)) => {
      push_stream_chunk(correlation_id, index, total, data, headers)
      true
    }
    None => false
  }
}

///|
struct StreamRoute {
  transport : &Transport
  target_addr : String
}

///|
fn collect_stream_routes(
  default_transport : &Transport,
  target_id : String,
  resolved_addr : String,
) -> Array[StreamRoute] {
  let routes : Array[StreamRoute] = []
  let seen : Map[String, Bool] = {}
  if !resolved_addr.is_empty() {
    let key = default_transport.protocol() + "|" + resolved_addr
    routes.push({ transport: default_transport, target_addr: resolved_addr })
    seen[key] = true
  }
  let connections = get_global_connection_manager().get_peer_connections(
    target_id,
  )
  for transport in get_registered_transports() {
    let protocol = transport.protocol()
    if protocol == "udp" {
      continue
    }
    let mut addr_opt = None
    for conn in connections {
      if conn.relay != 1 {
        continue
      }
      match conn.get_best_address(protocol) {
        Some(addr) => {
          addr_opt = Some(addr)
          break
        }
        None => ()
      }
    }
    match addr_opt {
      Some(addr) => {
        let key = protocol + "|" + addr
        if !seen.contains(key) {
          routes.push({ transport, target_addr: addr })
          seen[key] = true
        }
      }
      None => ()
    }
  }
  routes
}

///|
fn stream_chunk_headers(
  index : Int,
  status : String?,
  headers : Map[String, String]?,
) -> Map[String, String]? {
  if index == 0 {
    merge_stream_headers(status, headers)
  } else {
    None
  }
}

///|
async fn send_chunk_frame_or_fallback(
  default_transport : &Transport,
  default_addr : String,
  route : StreamRoute?,
  source_id : String,
  source_addr : String,
  target_id : String,
  correlation_id : String,
  is_encrypted : Bool,
  index : Int,
  total : Int,
  chunk : Bytes,
  status : String?,
  headers : Map[String, String]?,
) -> Unit {
  let chunk_headers = stream_chunk_headers(index, status, headers)
  let sent = match route {
    Some(route) =>
      route.transport.send(
        route.target_addr,
        encode_stream_frame(
          correlation_id, index, total, chunk, chunk_headers, is_encrypted,
        ),
      )
    None => false
  }
  if sent {
    return
  }

  let arr : Array[@msgpack.Value] = []
  arr.push(@msgpack.int(index))
  arr.push(@msgpack.int(total))
  arr.push(@msgpack.binary(b""))
  if index == 0 {
    match status {
      Some(s) => arr.push(@msgpack.string(s))
      None => if headers is Some(_) { arr.push(@msgpack.nil()) }
    }
    match headers {
      Some(h) => arr.push(headers_to_msgpack(h))
      None => ()
    }
  }
  let _ = send_one_helper(
    default_transport,
    default_addr,
    source_id,
    source_addr,
    target_id,
    correlation_id,
    is_encrypted,
    @msgpack.array(arr),
    Some(chunk),
  )
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
  if index < 0 || total <= 0 || index >= total {
    None
  } else {
    Some((index, total, data, status, headers))
  }
}

///|
fn parse_response_chunk_array(
  arr : Array[@msgpack.Value],
) -> (Int, Int, Bytes, String?, Map[String, String]?)? {
  if arr.length() < 3 {
    return None
  }
  let index = match arr[0] {
    Int(i) => i
    Int64(i) => i.to_int()
    UInt64(i) => i.reinterpret_as_int64().to_int()
    _ => -1
  }
  let total = match arr[1] {
    Int(i) => i
    Int64(i) => i.to_int()
    UInt64(i) => i.reinterpret_as_int64().to_int()
    _ => -1
  }
  let data = match arr[2] {
    Binary(b) => b
    _ => b""
  }
  let status = if arr.length() > 3 {
    match arr[3] {
      String(s) => Some(s)
      _ => None
    }
  } else {
    None
  }
  let headers = if arr.length() > 4 {
    match arr[4] {
      Map(m) => {
        let wrapper = Map::new()
        wrapper["headers"] = @msgpack.map(m)
        parse_headers_map(wrapper)
      }
      _ => None
    }
  } else {
    None
  }
  if index < 0 || total <= 0 || index >= total {
    None
  } else {
    Some((index, total, data, status, headers))
  }
}

///|
fn stream_done_from_headers(headers : Map[String, String]?) -> Bool {
  match headers {
    Some(h) =>
      match h.get("x-msgtier-stream-done") {
        Some(v) => v == "1"
        None => false
      }
    None => false
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
  let cache = app_data_handler_state.pending_response_chunks
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
  transport : &Transport,
  root : @async.TaskGroup[Unit],
  id : String,
  local_addr : String,
  sender_addr : String,
  msg : Message,
  data_value : @msgpack.Value,
) -> Unit {
  if check_and_mark_processed(msg.id, msg.timestamp) {
    log_warn("Duplicate or expired message \{msg.id} ignored")
    return
  }

  let data_content = match data_value {
    Binary(raw_data) => decode_binary_payload(raw_data)
    _ => data_value
  }
  root.spawn_bg(async fn() {
    let make_script_result = fn(status : String, message : String) {
      @msgpack.map({
        "status": @msgpack.string(status),
        "data": @msgpack.binary(@utf8.encode(message)),
      })
    }
    let content_str = if data_content is String(content) { content } else { "" }
    // Trim whitespace and remove null bytes from content string
    let cleaned = StringBuilder::new()
    for c in content_str {
      if c != '\u0000' {
        cleaned.write_char(c)
      }
    }
    let content_str = cleaned.to_string().trim().to_string()
    if content_str.is_empty() {
      log_warn("Received empty script content from \{msg.source_id}")
      send_response_message_direct(
        transport,
        sender_addr,
        id,
        local_addr,
        msg.source_id,
        msg.payload.unwrap_or(msg.id),
        ResponseSource::MsgPack(
          make_script_result("400", "Error: Empty script content"),
        ),
        None,
        false,
      )
      return
    }
    match execute_script_handler(content_str) {
      Some(output) =>
        send_response_message_direct(
          transport,
          sender_addr,
          id,
          local_addr,
          msg.source_id,
          msg.payload.unwrap_or(msg.id),
          ResponseSource::MsgPack(output.to_msgpack()),
          None,
          false,
        )
      None => {
        log_warn(
          "Script execution returned no output for message \{msg.id} content='\{content_str}'",
        )
        send_response_message_direct(
          transport,
          sender_addr,
          id,
          local_addr,
          msg.source_id,
          msg.payload.unwrap_or(msg.id),
          ResponseSource::MsgPack(
            make_script_result("500", "Error: No script output"),
          ),
          None,
          false,
        )
      }
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
    ctx.transport,
    ctx.root,
    ctx.my_id,
    ctx.local_addr,
    ctx.sender_addr,
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
      ResponseSource::MsgPack(@msgpack.map(resp_map)),
      Some(msg.encrypted),
      false,
    )
  })
}

///|
fn handle_http_proxy_message(ctx : MessageContext) -> Unit {
  let msg = ctx.msg
  let correlation_id = msg.payload.unwrap_or(msg.id)
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
  let (http_method, path, headers, body, prefer_stream_frame) = match msg.body {
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
      let prefer_stream_frame = match m.get("stream_mode") {
        Some(String(mode)) => mode == "frame_v1"
        _ => false
      }
      (http_method, path, headers, body, prefer_stream_frame)
    }
    _ => ("GET", "/", {}, b"", false)
  }
  log_bench(
    "http_proxy_recv",
    details="req=\{correlation_id} from=\{msg.source_id} path=\{path} stream=\{prefer_stream_frame}",
  )
  ctx.root.spawn_bg(async fn() {
    if prefer_stream_frame &&
      http_method == "POST" &&
      path == "/api/channels/chat/local/stream" {
      stream_internal_channel_chat_request(
        ctx.transport,
        ctx.sender_addr,
        ctx.my_id,
        ctx.local_addr,
        msg.source_id,
        correlation_id,
        body,
        msg.encrypted,
      )
      return
    }
    let (status_code, resp_headers, resp_body) = handle_internal_http_request(
      http_method, path, headers, body,
    )
    let resp_kind = match resp_body {
      Bytes(b) => "bytes:\{b.length()}"
      File(file_path) => "file:\{file_path}"
    }
    log_bench(
      "http_proxy_resp_ready",
      details="req=\{correlation_id} path=\{path} status=\{status_code} body=\{resp_kind}",
    )
    match resp_body {
      Bytes(b) => {
        let resp_map : Map[String, @msgpack.Value] = Map::new()
        resp_map["status"] = @msgpack.string(status_code.to_string())
        resp_map["headers"] = headers_to_msgpack(resp_headers)
        resp_map["data"] = @msgpack.binary(b)
        let use_encryption = if b.length() >=
          app_data_handler_state.http_proxy_no_encrypt_threshold {
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
          correlation_id,
          ResponseSource::MsgPack(@msgpack.map(resp_map)),
          Some(use_encryption),
          prefer_stream_frame,
        )
      }
      File(path) =>
        send_response_message_direct(
          ctx.transport,
          ctx.sender_addr,
          ctx.my_id,
          ctx.local_addr,
          msg.source_id,
          correlation_id,
          ResponseSource::FileStream(
            path,
            status_code.to_string(),
            resp_headers,
          ),
          Some(false),
          prefer_stream_frame,
        )
    }
  })
}

///|
enum ResponseSource {
  MsgPack(@msgpack.Value)
  FileStream(String, String, Map[String, String]) // path, status, headers
}

///|
async fn send_one_helper(
  transport : &Transport,
  resolved_addr : String,
  source_id : String,
  source_addr : String,
  target_id : String,
  correlation_id : String,
  is_encrypted : Bool,
  body : @msgpack.Value,
  attachment : Bytes?,
) -> Bool {
  let response_msg = match attachment {
    Some(a) =>
      Message::new(
        kind="response",
        source_id~,
        source_addr~,
        target_id~,
        relay=1,
        body~,
        encrypted=is_encrypted,
        payload=correlation_id,
        attachment=a,
      )
    None =>
      Message::new(
        kind="response",
        source_id~,
        source_addr~,
        target_id~,
        relay=1,
        body~,
        encrypted=is_encrypted,
        payload=correlation_id,
      )
  }
  let ok = send_message(transport, resolved_addr, response_msg) ||
    relay_message_with_route(transport, source_id, response_msg, target_id)
    is (true, Some(_))
  if !ok {
    add_pending_message(response_msg)
  }
  ok
}

///|
async fn send_chunked_helper(
  transport : &Transport,
  resolved_addr : String,
  source_id : String,
  source_addr : String,
  target_id : String,
  correlation_id : String,
  is_encrypted : Bool,
  data : Bytes,
  status : String?,
  headers : Map[String, String]?,
  prefer_stream_frame : Bool,
) -> Unit {
  let total = (data.length() + app_data_handler_state.response_chunk_size - 1) /
    app_data_handler_state.response_chunk_size
  let stream_routes = if prefer_stream_frame {
    collect_stream_routes(transport, target_id, resolved_addr)
  } else {
    []
  }
  log_bench(
    "stream_send_start",
    details="req=\{correlation_id} mode=bytes total=\{total} routes=\{stream_routes.length()}",
  )
  if stream_routes.length() <= 1 {
    let route = if stream_routes.length() == 1 {
      Some(stream_routes[0])
    } else {
      None
    }
    for i = 0; i < total; i = i + 1 {
      let start = i * app_data_handler_state.response_chunk_size
      let end = if start + app_data_handler_state.response_chunk_size >
        data.length() {
        data.length()
      } else {
        start + app_data_handler_state.response_chunk_size
      }
      let chunk = slice_bytes(data, start, end)
      send_chunk_frame_or_fallback(
        transport, resolved_addr, route, source_id, source_addr, target_id, correlation_id,
        is_encrypted, i, total, chunk, status, headers,
      )
    }
    log_bench(
      "stream_send_done",
      details="req=\{correlation_id} mode=bytes total=\{total}",
    )
    return
  }

  let prefix_end = if total < app_data_handler_state.stream_priority_chunks {
    total
  } else {
    app_data_handler_state.stream_priority_chunks
  }
  let primary_route = stream_routes[0]
  for i = 0; i < prefix_end; i = i + 1 {
    let start = i * app_data_handler_state.response_chunk_size
    let end = if start + app_data_handler_state.response_chunk_size >
      data.length() {
      data.length()
    } else {
      start + app_data_handler_state.response_chunk_size
    }
    let chunk = slice_bytes(data, start, end)
    send_chunk_frame_or_fallback(
      transport,
      resolved_addr,
      Some(primary_route),
      source_id,
      source_addr,
      target_id,
      correlation_id,
      is_encrypted,
      i,
      total,
      chunk,
      status,
      headers,
    )
  }
  if prefix_end >= total {
    log_bench(
      "stream_send_done",
      details="req=\{correlation_id} mode=bytes total=\{total}",
    )
    return
  }

  @async.with_task_group(fn(root) {
    let route_count = stream_routes.length()
    let remaining = total - prefix_end
    let primary_share = if remaining <= route_count {
      1
    } else {
      (remaining + route_count - 1) / route_count
    }
    let primary_end = if prefix_end + primary_share > total {
      total
    } else {
      prefix_end + primary_share
    }
    if prefix_end < primary_end {
      let route = primary_route
      root.spawn_bg(async fn() {
        for i = prefix_end; i < primary_end; i = i + 1 {
          let start = i * app_data_handler_state.response_chunk_size
          let end = if start + app_data_handler_state.response_chunk_size >
            data.length() {
            data.length()
          } else {
            start + app_data_handler_state.response_chunk_size
          }
          let chunk = slice_bytes(data, start, end)
          send_chunk_frame_or_fallback(
            transport,
            resolved_addr,
            Some(route),
            source_id,
            source_addr,
            target_id,
            correlation_id,
            is_encrypted,
            i,
            total,
            chunk,
            status,
            headers,
          )
        }
      })
    }
    let tail_start = primary_end
    let secondary_count = route_count - 1
    for route_idx = 1; route_idx < route_count; route_idx = route_idx + 1 {
      let route = stream_routes[route_idx]
      let local_idx = route_idx - 1
      let start_index = tail_start +
        local_idx * (total - tail_start) / secondary_count
      let end_index = tail_start +
        (local_idx + 1) * (total - tail_start) / secondary_count
      if start_index >= end_index {
        continue
      }
      root.spawn_bg(async fn() {
        for i = start_index; i < end_index; i = i + 1 {
          let start = i * app_data_handler_state.response_chunk_size
          let end = if start + app_data_handler_state.response_chunk_size >
            data.length() {
            data.length()
          } else {
            start + app_data_handler_state.response_chunk_size
          }
          let chunk = slice_bytes(data, start, end)
          send_chunk_frame_or_fallback(
            transport,
            resolved_addr,
            Some(route),
            source_id,
            source_addr,
            target_id,
            correlation_id,
            is_encrypted,
            i,
            total,
            chunk,
            status,
            headers,
          )
        }
      })
    }
  })
  log_bench(
    "stream_send_done",
    details="req=\{correlation_id} mode=bytes total=\{total}",
  )
}

///|
async fn send_file_stream_helper(
  transport : &Transport,
  resolved_addr : String,
  source_id : String,
  source_addr : String,
  target_id : String,
  correlation_id : String,
  is_encrypted : Bool,
  path : String,
  status : String,
  headers : Map[String, String]?,
  prefer_stream_frame : Bool,
) -> Unit {
  let file_size = try {
    let file = @fs.open(path, mode=ReadOnly)
    defer file.close()
    file.size()
  } catch {
    e => {
      log_error("File stream error: " + e.to_string())
      let resp_map : Map[String, @msgpack.Value] = Map::new()
      resp_map["status"] = @msgpack.string("500")
      resp_map["headers"] = headers_to_msgpack(headers.unwrap_or({}))
      resp_map["data"] = @msgpack.binary(
        @utf8.encode("Internal Server Error: " + e.to_string()),
      )
      let _ = send_one_helper(
        transport,
        resolved_addr,
        source_id,
        source_addr,
        target_id,
        correlation_id,
        is_encrypted,
        @msgpack.map(resp_map),
        None,
      )
      return
    }
  }
  let chunk_size_64 = app_data_handler_state.response_chunk_size.to_int64()
  let total_64 = (file_size + chunk_size_64 - 1) / chunk_size_64
  let total = total_64.to_int()
  let stream_routes = if prefer_stream_frame {
    collect_stream_routes(transport, target_id, resolved_addr)
  } else {
    []
  }
  log_bench(
    "stream_send_start",
    details="req=\{correlation_id} mode=file total=\{total} routes=\{stream_routes.length()}",
  )

  if stream_routes.length() <= 1 {
    let route = if stream_routes.length() == 1 {
      Some(stream_routes[0])
    } else {
      None
    }
    try {
      let file = @fs.open(path, mode=ReadOnly)
      defer file.close()
      for i = 0; i < total; i = i + 1 {
        let offset = i.to_int64() * chunk_size_64
        let expected_len = if offset + chunk_size_64 > file_size {
          (file_size - offset).to_int()
        } else {
          app_data_handler_state.response_chunk_size
        }
        let chunk_buf = FixedArray::make(expected_len, b'\x00')
        let bytes_read = file.read_at(chunk_buf, position=offset)
        if bytes_read <= 0 {
          continue
        }
        let chunk_full = chunk_buf.unsafe_reinterpret_as_bytes()
        let chunk = if bytes_read < expected_len {
          slice_bytes(chunk_full, 0, bytes_read)
        } else {
          chunk_full
        }
        send_chunk_frame_or_fallback(
          transport,
          resolved_addr,
          route,
          source_id,
          source_addr,
          target_id,
          correlation_id,
          is_encrypted,
          i,
          total,
          chunk,
          Some(status),
          headers,
        )
      }
    } catch {
      e => log_error("File stream error: " + e.to_string())
    }
    log_bench(
      "stream_send_done",
      details="req=\{correlation_id} mode=file total=\{total}",
    )
    return
  }

  let prefix_end = if total < app_data_handler_state.stream_priority_chunks {
    total
  } else {
    app_data_handler_state.stream_priority_chunks
  }
  let primary_route = stream_routes[0]
  try {
    let file = @fs.open(path, mode=ReadOnly)
    defer file.close()
    for i = 0; i < prefix_end; i = i + 1 {
      let offset = i.to_int64() * chunk_size_64
      let expected_len = if offset + chunk_size_64 > file_size {
        (file_size - offset).to_int()
      } else {
        app_data_handler_state.response_chunk_size
      }
      let chunk_buf = FixedArray::make(expected_len, b'\x00')
      let bytes_read = file.read_at(chunk_buf, position=offset)
      if bytes_read <= 0 {
        continue
      }
      let chunk_full = chunk_buf.unsafe_reinterpret_as_bytes()
      let chunk = if bytes_read < expected_len {
        slice_bytes(chunk_full, 0, bytes_read)
      } else {
        chunk_full
      }
      send_chunk_frame_or_fallback(
        transport,
        resolved_addr,
        Some(primary_route),
        source_id,
        source_addr,
        target_id,
        correlation_id,
        is_encrypted,
        i,
        total,
        chunk,
        Some(status),
        headers,
      )
    }
  } catch {
    e => {
      log_error("File stream error: " + e.to_string())
      return
    }
  }
  if prefix_end >= total {
    log_bench(
      "stream_send_done",
      details="req=\{correlation_id} mode=file total=\{total}",
    )
    return
  }

  @async.with_task_group(fn(root) {
    let route_count = stream_routes.length()
    let remaining = total - prefix_end
    let primary_share = if remaining <= route_count {
      1
    } else {
      (remaining + route_count - 1) / route_count
    }
    let primary_end = if prefix_end + primary_share > total {
      total
    } else {
      prefix_end + primary_share
    }
    if prefix_end < primary_end {
      let route = primary_route
      root.spawn_bg(async fn() {
        try {
          let file = @fs.open(path, mode=ReadOnly)
          defer file.close()
          for i = prefix_end; i < primary_end; i = i + 1 {
            let offset = i.to_int64() * chunk_size_64
            let expected_len = if offset + chunk_size_64 > file_size {
              (file_size - offset).to_int()
            } else {
              app_data_handler_state.response_chunk_size
            }
            let chunk_buf = FixedArray::make(expected_len, b'\x00')
            let bytes_read = file.read_at(chunk_buf, position=offset)
            if bytes_read <= 0 {
              continue
            }
            let chunk_full = chunk_buf.unsafe_reinterpret_as_bytes()
            let chunk = if bytes_read < expected_len {
              slice_bytes(chunk_full, 0, bytes_read)
            } else {
              chunk_full
            }
            send_chunk_frame_or_fallback(
              transport,
              resolved_addr,
              Some(route),
              source_id,
              source_addr,
              target_id,
              correlation_id,
              is_encrypted,
              i,
              total,
              chunk,
              Some(status),
              headers,
            )
          }
        } catch {
          e => log_error("File stream route error: " + e.to_string())
        }
      })
    }
    let tail_start = primary_end
    let secondary_count = route_count - 1
    for route_idx = 1; route_idx < route_count; route_idx = route_idx + 1 {
      let route = stream_routes[route_idx]
      let local_idx = route_idx - 1
      let start_index = tail_start +
        local_idx * (total - tail_start) / secondary_count
      let end_index = tail_start +
        (local_idx + 1) * (total - tail_start) / secondary_count
      if start_index >= end_index {
        continue
      }
      root.spawn_bg(async fn() {
        try {
          let file = @fs.open(path, mode=ReadOnly)
          defer file.close()
          for i = start_index; i < end_index; i = i + 1 {
            let offset = i.to_int64() * chunk_size_64
            let expected_len = if offset + chunk_size_64 > file_size {
              (file_size - offset).to_int()
            } else {
              app_data_handler_state.response_chunk_size
            }
            let chunk_buf = FixedArray::make(expected_len, b'\x00')
            let bytes_read = file.read_at(chunk_buf, position=offset)
            if bytes_read <= 0 {
              continue
            }
            let chunk_full = chunk_buf.unsafe_reinterpret_as_bytes()
            let chunk = if bytes_read < expected_len {
              slice_bytes(chunk_full, 0, bytes_read)
            } else {
              chunk_full
            }
            send_chunk_frame_or_fallback(
              transport,
              resolved_addr,
              Some(route),
              source_id,
              source_addr,
              target_id,
              correlation_id,
              is_encrypted,
              i,
              total,
              chunk,
              Some(status),
              headers,
            )
          }
        } catch {
          e => log_error("File stream route error: " + e.to_string())
        }
      })
    }
  })
  log_bench(
    "stream_send_done",
    details="req=\{correlation_id} mode=file total=\{total}",
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
  response_source : ResponseSource,
  encrypted_override : Bool?,
  prefer_stream_frame : Bool,
) -> Unit {
  let config = get_config()
  let default_encrypted = config.is_encrypt()
  let is_encrypted = match encrypted_override {
    Some(v) => v
    None => default_encrypted
  }
  let resolved_addr = if target_addr.is_empty() {
    pick_peer_address(target_id, transport.protocol()).unwrap_or(target_addr)
  } else {
    target_addr
  }
  match response_source {
    ResponseSource::MsgPack(response_data) =>
      match response_data {
        Binary(b) =>
          if b.length() >= app_data_handler_state.response_chunk_size {
            send_chunked_helper(
              transport,
              resolved_addr,
              source_id,
              source_addr,
              target_id,
              correlation_id,
              is_encrypted,
              b,
              None,
              None,
              prefer_stream_frame,
            )
          } else {
            let _ = send_one_helper(
              transport,
              resolved_addr,
              source_id,
              source_addr,
              target_id,
              correlation_id,
              is_encrypted,
              response_data,
              None,
            )
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
              if data.length() >= app_data_handler_state.response_chunk_size {
                send_chunked_helper(
                  transport,
                  resolved_addr,
                  source_id,
                  source_addr,
                  target_id,
                  correlation_id,
                  is_encrypted,
                  data,
                  Some(status),
                  headers,
                  prefer_stream_frame,
                )
              } else {
                let _ = send_one_helper(
                  transport,
                  resolved_addr,
                  source_id,
                  source_addr,
                  target_id,
                  correlation_id,
                  is_encrypted,
                  response_data,
                  None,
                )
              }
            _ => {
              let _ = send_one_helper(
                transport,
                resolved_addr,
                source_id,
                source_addr,
                target_id,
                correlation_id,
                is_encrypted,
                response_data,
                None,
              )
            }
          }
        }
        _ => {
          let _ = send_one_helper(
            transport,
            resolved_addr,
            source_id,
            source_addr,
            target_id,
            correlation_id,
            is_encrypted,
            response_data,
            None,
          )
        }
      }
    ResponseSource::FileStream(path, status, headers) =>
      send_file_stream_helper(
        transport,
        resolved_addr,
        source_id,
        source_addr,
        target_id,
        correlation_id,
        is_encrypted,
        path,
        status,
        Some(headers),
        prefer_stream_frame,
      )
  }
  log_info(
    "DataResponse: direct correlation=\{correlation_id} to=\{target_id} encrypted=\{is_encrypted}",
  )
}

///|
async fn stream_internal_channel_chat_request(
  transport : &Transport,
  target_addr : String,
  source_id : String,
  source_addr : String,
  target_id : String,
  correlation_id : String,
  body : Bytes,
  is_encrypted : Bool,
) -> Unit {
  let body_str = @utf8.decode(body)
  match parse_channel_chat_request(body_str) {
    Some((peer_id, channel_id, channel_type, messages, session_key, _)) => {
      let (status_code, response_body) = local_channel_chat_request(
        channel_id, channel_type, messages, session_key, false,
      )
      if status_code < 200 || status_code >= 300 {
        let resp_map : Map[String, @msgpack.Value] = Map::new()
        resp_map["status"] = @msgpack.string(status_code.to_string())
        resp_map["headers"] = headers_to_msgpack({
          "Content-Type": "application/json",
          "x-msgtier-stream-done": "1",
        })
        resp_map["data"] = @msgpack.binary(
          @utf8.encode(response_body.stringify()),
        )
        send_response_message_direct(
          transport,
          target_addr,
          source_id,
          source_addr,
          target_id,
          correlation_id,
          ResponseSource::MsgPack(@msgpack.map(resp_map)),
          Some(is_encrypted),
          false,
        )
        return
      }
      let events = make_channel_stream_events(
        peer_id, channel_id, channel_type, response_body,
      )
      let mut idx = 0
      for event_chunk in events {
        let headers : Map[String, String] = if idx == 0 {
          {
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "x-msgtier-stream-done": "0",
          }
        } else if idx == events.length() - 1 {
          { "x-msgtier-stream-done": "1" }
        } else {
          { "x-msgtier-stream-done": "0" }
        }
        let resp_map : Map[String, @msgpack.Value] = Map::new()
        resp_map["status"] = @msgpack.string("200")
        resp_map["headers"] = headers_to_msgpack(headers)
        resp_map["data"] = @msgpack.binary(@utf8.encode(event_chunk))
        send_response_message_direct(
          transport,
          target_addr,
          source_id,
          source_addr,
          target_id,
          correlation_id,
          ResponseSource::MsgPack(@msgpack.map(resp_map)),
          Some(is_encrypted),
          false,
        )
        idx = idx + 1
        @async.sleep(10)
      }
    }
    None => {
      let resp_map : Map[String, @msgpack.Value] = Map::new()
      resp_map["status"] = @msgpack.string("400")
      resp_map["headers"] = headers_to_msgpack({
        "Content-Type": "application/json",
        "x-msgtier-stream-done": "1",
      })
      resp_map["data"] = @msgpack.binary(
        @utf8.encode(
          { "error": "invalid_channel_chat_request" }.to_json().stringify(),
        ),
      )
      send_response_message_direct(
        transport,
        target_addr,
        source_id,
        source_addr,
        target_id,
        correlation_id,
        ResponseSource::MsgPack(@msgpack.map(resp_map)),
        Some(is_encrypted),
        false,
      )
    }
  }
}

///|
fn handle_data_response(
  correlation_id : String,
  response_data : @msgpack.Value,
  attachment : Bytes?,
  source_id : String,
) -> Unit {
  log_debug(
    "DataResponse: resolve correlation=\{correlation_id} from=\{source_id}",
  )
  if is_stream_request(correlation_id) {
    match response_data {
      Binary(b) => push_stream_data(correlation_id, b, None)
      Array(arr) =>
        match parse_response_chunk_array(arr) {
          Some((index, total, data, status, headers)) => {
            let real_data = match attachment {
              Some(b) => b
              None => data
            }
            let merged_headers = match status {
              Some(s) => Some(ensure_status_header(s, headers))
              None => headers
            }
            push_stream_chunk(
              correlation_id, index, total, real_data, merged_headers,
            )
          }
          None => {
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
                push_stream_data_part(
                  correlation_id,
                  data,
                  merged_headers,
                  stream_done_from_headers(merged_headers),
                )
              }
              _ => {
                let output = match m.get("output") {
                  Some(String(s)) => s
                  _ => response_data.to_string().unwrap_or("error")
                }
                push_stream_data_part(
                  correlation_id,
                  @utf8.encode(output),
                  None,
                  true,
                )
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
    Array(arr) =>
      match parse_response_chunk_array(arr) {
        Some((index, total, data, status, headers)) => {
          let real_data = match attachment {
            Some(b) => b
            None => data
          }
          match
            store_response_chunk(
              correlation_id, index, total, real_data, status, headers,
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
        }
        None => {
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
