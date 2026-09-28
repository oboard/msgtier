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
  store: { objects: Map([]), },
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
  if !is_valid_object_id(id) {
    return None
  }
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
  save_object_from_reader(id, @io.MemoryReader(writer => writer.write(data)))
}

///|
pub async fn save_object_from_reader(id : String, reader : &@io.Reader) -> Unit {
  save_object_in_dir(get_upload_dir(), id, reader)
}

///|
fn is_valid_object_id(id : String) -> Bool {
  !id.is_empty() &&
  !id.has_prefix(".") &&
  !id.contains("/") &&
  !id.contains("\\") &&
  !id.contains("\u0000")
}

///|
suberror ObjectUploadReadError {
  ObjectUploadReadError(String)
} derive(Debug)

///|
/// Publish only complete uploads. A cancelled or failed upload must not leave
/// a downloadable partial object, and memory use must not depend on file size.
async fn save_object_in_dir(
  dir : String,
  id : String,
  reader : &@io.Reader,
) -> Unit {
  if !is_valid_object_id(id) {
    fail("invalid object id")
  }
  @fs.mkdir(dir, permission=0o755, recursive=true, allow_exist=true)
  let suffix = @nanoid.nanoid().unwrap_or(@env.now().to_string())
  let temporary_path = dir + "/.upload-" + suffix
  let file = @fs.open(
    temporary_path,
    mode=WriteOnly,
    create_mode=@fs.CreateNew,
    permission=0o644,
  )
  let mut committed = false
  defer {
    file.close()
    if !committed {
      @fs.remove(temporary_path) catch {
        err => log_warn("Failed to remove incomplete upload: \{err}")
      }
    }
  }
  let buf = FixedArray::make(65536, b'\x00')
  for ;; {
    let n = @async.with_timeout(60000, () => {
      reader.read(buf) catch {
        err => raise ObjectUploadReadError(err.to_string())
      }
    })
    if n == 0 {
      break
    }
    file.write(buf.unsafe_reinterpret_as_bytes()[:n])
  }
  file.close()
  @fs.rename(temporary_path, dir + "/" + id, replace=true)
  committed = true
}

///|
pub fn has_object(id : String) -> Bool {
  object_store_state.store.objects.contains(id)
}
