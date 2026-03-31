///|
struct ObjectStore {
  // Mapping from object ID to local file path
  objects : Map[String, String]
}

///|
struct ObjectStoreState {
  store : ObjectStore
  mut default_upload_dir : String
}

///|
let object_store_state : ObjectStoreState = {
  store: { objects: {} },
  default_upload_dir: "",
}

///|
pub fn register_object(path : String, id? : String) -> String {
  let object_id = match id {
    Some(id) => id
    None => @nanoid.nanoid().unwrap_or(@env.now().to_string())
  }
  object_store_state.store.objects[object_id] = path
  object_id
}

///|
async fn init_upload_dir() -> Unit {
  object_store_state.default_upload_dir = @fs.tmpdir(prefix="msgtier")
}

///|
pub fn get_runtime_tmp_dir() -> String {
  object_store_state.default_upload_dir
}

///|
fn get_upload_dir() -> String {
  match get_config().upload_dir {
    Some(dir) => dir
    None => object_store_state.default_upload_dir
  }
}

///|
pub async fn get_object_path(id : String) -> String? {
  // Check registered objects first
  if object_store_state.store.objects.contains(id) {
    match object_store_state.store.objects.get(id) {
      Some(path) => if @fs.exists(path) { return Some(path) }
      None => ()
    }
  }

  // Fallback to upload_dir
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
pub async fn save_object(id : String, data : Bytes) -> Unit {
  let dir = get_upload_dir()
  if !@fs.exists(dir) {
    @fs.mkdir(dir, permission=0o644)
  }
  let path = dir + "/" + id
  @fs.write_file(path, data, create=0o644)
}

///|
pub async fn save_object_from_reader(id : String, reader : &@io.Reader) -> Unit {
  let dir = get_upload_dir()
  if !@fs.exists(dir) {
    @fs.mkdir(dir, permission=0o644)
  }
  let path = dir + "/" + id
  let file = @fs.open(path, mode=WriteOnly, create=0o644, truncate=true)
  defer file.close()

  let buf = FixedArray::make(4194304, b'\x00') // 4MB buffer
  for ;; {
    let n = reader.read(buf)
    if n <= 0 {
      break
    }
    let full = buf.unsafe_reinterpret_as_bytes()
    let chunk = if n < 4194304 { slice_bytes(full, 0, n) } else { full }
    file.write(chunk)
  }
}

///|
pub fn has_object(id : String) -> Bool {
  object_store_state.store.objects.contains(id)
}
