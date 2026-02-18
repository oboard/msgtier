///|
const VERSION = "0.1.0"

///|
let global_config : Ref[Config?] = Ref::new(None)

///|
async fn main {
  @async.with_task_group(async fn(root) {
    let args = @env.args()[1:]
    match args {
      [""] | ["--help"] => {
        log_info("Usage: msgtier [config.json]")
        return
      }
      ["web", "update"] => {
        let (res, _) = @http.get(
          "https://nightly.link/oboard/msgtier-web/workflows/build/main/dist.zip",
        )
        // println(res.headers)
        let (_, data) = @http.get(res.headers["location"])
        let data = data.binary()
        // println(data.length())
        match @zipc.of_bytes(data) {
          Ok(archive) => update_web_dist(archive)
          Err(e) => log_error("Error extracting zip: \{e}")
        }
      }
      ["--version"] => {
        log_info("Version: \{VERSION}")
        return
      }
      [config] => {
        let config = Config::from_file(config)

        // Initialize X25519 key pair from config
        init_keypair(config.secret)

        // Store config globally for access by listeners
        global_config.val = Some(config)
        log_debug(config.to_json().stringify(indent=2))
        log_debug("DEBUG: My Public Key: \{bytes_to_hex(get_public_key())}")
        let id = config.id

        // Initialize object store
        init_object_store(dir="data/objects_" + id)

        // Initialize shared secret with self for loopback encryption
        compute_and_store_shared_secret(id, get_public_key())

        // Initialize known peers from config
        for peer_url in config.peers {
          add_known_peer(peer_url)
        }

        // Initialize ForeignNetworkManager
        init_foreign_network_manager(config)

        // Don't pre-create peers - they will be created when hello messages arrive
        for listener in config.listeners {
          match @url.Url::parse(listener) {
            Some(url) => {
              let host = url.get_host()
              let scheme = url.scheme
              let _ : @async.Task[Unit] = root.spawn(async fn() {
                for {
                  try {
                    log_info("Attempting to listen on \{listener}")
                    let transport = match scheme {
                      "tcp" => (TcpTransport::new(host) : &Transport)
                      "udp" => (UdpTransport::new(host) : &Transport)
                      "ws" => (WebSocketTransport::new(host) : &Transport)
                      "quic" => (QuicTransport::new(host) : &Transport)
                      _ => abort("Unknown protocol: \{scheme}")
                    }
                    log_info("Successfully bound to \{listener}")
                    start_listener_service(root, transport, id)
                  } catch {
                    e =>
                      log_warn(
                        "Failed to start listener on \{listener}: \{e}. Retrying in 5s...",
                      )
                  }
                  @async.sleep(5000)
                }
              })
            }
            None => log_warn("Invalid listener URL: \{listener}")
          }
        }
        if config.web_api is Some(addr) {
          let _ : @async.Task[Unit] = root.spawn(async fn() {
            log_info("HTTP API listening on http://\{addr}")
            start_http_service(addr, config)
          })
        }
      }
      _ => log_info("MsgTier 0.1")
    }
  })
}

///|
async fn update_web_dist(archive : @zipc.Archive) -> Unit {
  let output_root = "web/dist"
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
