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
    None => @uuidm.v4().to_string()
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
    None => log_warn("ObjectStore: requested object id=\{object_id} not found")
    // Optionally send 404 response
  }
}

///|
pub fn handle_object_response(msg : Message) -> Unit {
  let request_id = msg.payload.unwrap_or("")
  if request_id == "" {
    return
  }

  let data = match msg.body {
    Binary(b) => b
    _ => return
  }

  log_info(
    "ObjectStore: received response for request id=\{request_id} size=\{data.length()}",
  )
  resolve_request(request_id, {}, data)
}

///|
pub async fn get_object(id : String) -> Bytes? {
  match global_object_store.objects.get(id) {
    Some(path) =>
      try {
        if @fs.exists(path) {
          Some(@fs.read_file(path).binary())
        } else {
          None
        }
      } catch {
        _ => None
      }
    None => None
  }
}

///|
pub async fn save_object(data : Bytes, id? : String) -> String {
  let object_id = match id {
    Some(id) => id
    None => @uuidm.v4().to_string()
  }

  let upload_dir = get_config().upload_dir.unwrap_or("uploads")
  // Ensure uploads directory exists
  if !@fs.exists(upload_dir) {
    @fs.mkdir(upload_dir, permission=493)
  }

  let path = upload_dir + "/" + object_id
  try {
    @fs.write_file(path, data)
    global_object_store.objects[object_id] = path
  } catch {
    _ => log_error("Failed to save object to " + path)
  }

  object_id
}

///|
pub fn has_object(id : String) -> Bool {
  global_object_store.objects.contains(id)
}
