///|
pub let dist : Map[StringView, Bytes] = {}

///|
fn init {
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
