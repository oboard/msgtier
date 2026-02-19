///|
const WEB_UPDATE_URL = "https://nightly.link/oboard/msgtier-web/workflows/build/main/dist.zip"

///|
async fn handle_web_update() -> Unit {
  let (res, _) = @http.get(WEB_UPDATE_URL)
  let (_, data) = @http.get(res.headers["location"])
  let data = data.binary()
  match @zipc.of_bytes(data) {
    Ok(archive) => update_web_dist(archive)
    Err(e) => log_error("Error extracting zip: \{e}")
  }
}

///|
async fn update_web_dist(archive : @zipc.Archive) -> Unit {
  let output_root = "web/dist"
  if @fs.exists(output_root) {
    @fs.rmdir(output_root, recursive=true)
  }
  ensure_dir(output_root)
  let mut written = 0
  let mut skipped = 0
  for _, mem in archive.members {
    let rel_path = @zipc.member_path(mem)
    if !is_safe_zip_path(rel_path) {
      skipped = skipped + 1
      log_warn("Skipping unsafe path: \{rel_path}")
      continue
    }
    match @zipc.member_kind(mem) {
      @zipc.MemberKind::Dir => {
        let dir_path = normalize_dir_path(rel_path)
        if dir_path != "" {
          ensure_dir(output_root + "/" + dir_path)
        }
      }
      @zipc.MemberKind::File(file) => {
        let parent_dir = parent_dir_path(rel_path)
        if parent_dir != "" {
          ensure_dir(output_root + "/" + parent_dir)
        }
        try {
          let bytes = @zipc.file_to_bytes(file)
          @fs.write_file(output_root + "/" + rel_path, bytes, create=0o644) catch {
            e => {
              skipped = skipped + 1
              log_warn("Failed to write \{rel_path}: \{e}")
            }
          }
          written = written + 1
        } catch {
          e => {
            skipped = skipped + 1
            log_warn("Failed to extract \{rel_path}: \{e}")
          }
        }
      }
    }
  }
  log_info("Web UI updated: \{written} files written, \{skipped} skipped")
}

///|
fn normalize_dir_path(path : String) -> String {
  match path.strip_suffix("/") {
    Some(p) => p.to_string()
    None => path
  }
}

///|
fn parent_dir_path(path : String) -> String {
  let parts = path.split("/").collect()
  if parts.length() <= 1 {
    return ""
  }
  let builder = StringBuilder::new()
  let mut first = true
  for i = 0; i < parts.length() - 1; i = i + 1 {
    let seg = parts[i]
    if seg == "" {
      continue
    }
    if first {
      first = false
    } else {
      builder.write_string("/")
    }
    builder.write_string(seg.to_string())
  }
  builder.to_string()
}

///|
fn is_safe_zip_path(path : String) -> Bool {
  if path.length() == 0 {
    return false
  }
  match path[:] {
    ['/' | '\\', ..] => return false
    _ => ()
  }
  let parts = path.split("/").collect()
  for seg in parts {
    if seg == ".." {
      return false
    }
  }
  true
}

///|
async fn ensure_dir(path : String) -> Unit {
  if path == "" {
    return
  }
  let exists = @fs.exists(path) catch { _ => false }
  if exists {
    return
  }
  @fs.mkdir(path, permission=0o755, recursive=true) catch {
    e => log_warn("Failed to create directory \{path}: \{e}")
  }
}
