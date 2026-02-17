///|
struct ObjectStore {
  mut root_dir : String
}

///|
let global_object_store : ObjectStore = { root_dir: "data/objects" }

///|
pub async fn init_object_store(dir? : String) -> Unit {
  match dir {
    Some(d) => global_object_store.root_dir = d
    None => ()
  }

  let d = global_object_store.root_dir
  if not(@fs.exists(d)) {
    @fs.mkdir(d, permission=0o755) catch {
      _ => log_warn("Failed to create object store directory: \{d}")
    }
  }
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
  let path = global_object_store.root_dir + "/" + id
  try {
    if @fs.exists(path) {
      Some(@fs.read_file(path).binary())
    } else {
      None
    }
  } catch {
    _ => None
  }
}

///|
pub async fn save_object(data : Bytes, id? : String) -> String {
  let object_id = match id {
    Some(id) => id
    None => @uuidm.v4().to_string()
  }

  let path = global_object_store.root_dir + "/" + object_id
  @fs.write_file(path, data) catch {
    e => log_warn("Failed to save object: \{e}")
  }
  object_id
}

///|
pub async fn has_object(id : String) -> Bool {
  let path = global_object_store.root_dir + "/" + id
  @fs.exists(path)
}
