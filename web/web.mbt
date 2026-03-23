///|
pub let dist : Map[StringView, Bytes] = {}

///|
let dist_loaded : Ref[Bool] = Ref::new(false)

///|
fn load_dist_archive() -> Unit {
  match @zipc.of_bytes(resource) {
    Ok(archive) =>
      for entity in archive.members {
        let (path, m) = entity
        if m.kind is File(file) {
          dist[path] = @zipc.file_to_bytes(file) catch { _ => continue }
        }
      }
    Err(e) => println("Error extracting zip: \{e}")
  }
}

///|
pub fn ensure_dist_loaded() -> Unit {
  if dist_loaded.val {
    return
  }
  load_dist_archive()
  dist_loaded.val = true
}
