///|
struct ObjectStore {
  // Mapping from object ID to local file path
  objects : Map[String, String]
}

///|
let global_object_store : ObjectStore = { objects: {} }

///|
pub fn register_object(path : String, id? : String) -> String {
  let object_id = match id {
    Some(id) => id
    None => @uuidm.v4().to_string_simple()
  }
  global_object_store.objects[object_id] = path
  object_id
}

///|
pub async fn handle_object_request(msg : Message) -> Unit {
  let object_id = match msg.body {
    String(s) => s
    _ => return
  }

  log_info(
    "ObjectStore: received request for object id=\{object_id} from=\{msg.source_id}",
  )

  let data_opt = get_object(object_id) catch { _ => None }

  match data_opt {
    Some(data) => {
      let response_msg = Message::new(
        kind="object_response",
        source_id=get_config().id,
        target_id=msg.source_id,
        payload=msg.payload.unwrap_or(""),
        body=@msgpack.binary(data),
        relay=1,
      )
      add_pending_message(response_msg)
      log_info(
        "ObjectStore: sent response for object id=\{object_id} to=\{msg.source_id}",
      )
    }
    None => {
      log_warn("ObjectStore: requested object id=\{object_id} not found")
      // Send 404 response
      let response_msg = Message::new(
        kind="object_response",
        source_id=get_config().id,
        target_id=msg.source_id,
        payload=msg.payload.unwrap_or(""),
        body=@msgpack.string("not_found"),
        relay=1,
      )
      add_pending_message(response_msg)
    }
  }
}

///|
pub async fn handle_file_chunk_request(msg : Message) -> Unit {
  let (id, offset, size) = match msg.body {
    Map(m) => {
      let id = match m.get("id") {
        Some(String(s)) => s
        _ => return
      }
      let offset = match m.get("offset") {
        Some(Int64(i)) => i
        Some(UInt64(i)) => i.reinterpret_as_int64()
        Some(Int(i)) => i.to_int64()
        _ => 0L
      }
      let size = match m.get("size") {
        Some(Int(i)) => i
        Some(Int64(i)) => i.to_int()
        Some(UInt64(i)) => i.reinterpret_as_int64().to_int()
        _ => 65536
      }
      (id, offset, size)
    }
    _ => return
  }

  log_info(
    "ObjectStore: received chunk request for object id=\{id} offset=\{offset} size=\{size} from=\{msg.source_id}",
  )

  let data_opt = get_object_chunk(id, offset, size)

  match data_opt {
    Some(data) => {
      let response_msg = Message::new(
        kind="object_response",
        source_id=get_config().id,
        target_id=msg.source_id,
        payload=msg.payload.unwrap_or(""),
        body=@msgpack.binary(data),
        relay=1,
      )
      add_pending_message(response_msg)
    }
    None => {
      log_warn("ObjectStore: requested chunk for object id=\{id} not found")
      let response_msg = Message::new(
        kind="object_response",
        source_id=get_config().id,
        target_id=msg.source_id,
        payload=msg.payload.unwrap_or(""),
        body=@msgpack.string("not_found"),
        relay=1,
      )
      add_pending_message(response_msg)
    }
  }
}

///|
pub fn handle_object_response(msg : Message) -> Unit {
  let request_id = msg.payload.unwrap_or("")
  if request_id == "" {
    return
  }

  let (data, headers) = match msg.body {
    Binary(b) => (b, {})
    String("not_found") => (b"", { "status": "404" })
    _ => return
  }

  log_info(
    "ObjectStore: received response for request id=\{request_id} size=\{data.length()} headers=\{headers}",
  )
  resolve_request(request_id, headers, data)
}

///|
let default_upload_dir : Ref[String] = Ref::new("")

///|
async fn init_upload_dir() -> Unit {
  default_upload_dir.val = @fs.tmpdir(prefix="msgtier")
}

///|
fn get_upload_dir() -> String {
  match get_config().upload_dir {
    Some(dir) => dir
    None => default_upload_dir.val
  }
}

///|
pub async fn get_object_path(id : String) -> String? {
  let dir = get_upload_dir()
  let path = dir + "/" + id
  if @fs.exists(path) {
    Some(path)
  } else {
    None
  }
}

///|
pub async fn get_object(id : String) -> Bytes? {
  match get_object_path(id) {
    Some(path) => Some(@fs.read_file(path).binary()) catch { _ => None }
    None => None
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
async fn get_object_chunk(id : String, offset : Int64, size : Int) -> Bytes? {
  match get_object_path(id) {
    Some(path) =>
      try {
        // Temporary implementation using read_file until fs API is confirmed
        let all_data = @fs.read_file(path).binary()
        let len = all_data.length().to_int64()
        if offset >= len {
          None
        } else {
          let end = offset + size.to_int64()
          let actual_end = if end > len { len } else { end }
          let chunk = slice_bytes(
            all_data,
            offset.to_int(),
            actual_end.to_int(),
          )
          Some(chunk)
        }
      } catch {
        _ => None
      }
    None => None
  }
}

///|
pub async fn save_object(id : String, data : Bytes) -> Unit {
  let dir = get_upload_dir()
  if not(@fs.exists(dir)) {
    @fs.mkdir(dir, permission=0o644)
  }
  let path = dir + "/" + id
  @fs.write_file(path, data, create=0o644)
}

///|
pub fn has_object(id : String) -> Bool {
  global_object_store.objects.contains(id)
}
