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
    None => @nanoid.nanoid().unwrap_or(@env.now().to_string())
  }
  global_object_store.objects[object_id] = path
  object_id
}

///|
let default_upload_dir : Ref[String] = Ref::new("")

///|
async fn init_upload_dir() -> Unit {
  default_upload_dir.val = @fs.tmpdir(prefix="msgtier")
}

///|
pub fn get_runtime_tmp_dir() -> String {
  default_upload_dir.val
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
  // Check registered objects first
  if global_object_store.objects.contains(id) {
    match global_object_store.objects.get(id) {
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
  if not(@fs.exists(dir)) {
    @fs.mkdir(dir, permission=0o644)
  }
  let path = dir + "/" + id
  @fs.write_file(path, data, create=0o644)
}

///|
pub async fn save_object_from_reader(id : String, reader : &@io.Reader) -> Unit {
  let dir = get_upload_dir()
  if not(@fs.exists(dir)) {
    @fs.mkdir(dir, permission=0o644)
  }
  let path = dir + "/" + id
  let file = @fs.open(path, mode=WriteOnly, create=0o644, truncate=true)
  defer file.close()

  let buf = FixedArray::make(4194304, b'\x00') // 4MB buffer
  for {
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
  global_object_store.objects.contains(id)
}
