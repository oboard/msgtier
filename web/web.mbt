///|
pub let dist : Map[StringView, Bytes] = Map([])

///|
let dist_loaded : Ref[Bool] = Ref(false)

///|
fn load_dist_archive() -> Unit {
  try {
    let archive = @zipc.Archive::from_bytes(resource)
    for entry in archive.to_array() {
      if entry.kind() is File(file) {
        let data = file.to_bytes() catch { _ => continue }
        dist[entry.path()] = data
      }
    }
  } catch {
    err => println("Error extracting zip: \{err}")
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
