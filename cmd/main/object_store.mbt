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
pub fn has_object(id : String) -> Bool {
  global_object_store.objects.contains(id)
}
