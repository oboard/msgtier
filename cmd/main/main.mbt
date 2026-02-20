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
        print_usage()
        return
      }
      ["--version"] => {
        log_info("Version: \{VERSION}")
        return
      }
      [config] => run_with_config(root, config)
      _ => log_info("MsgTier 0.1")
    }
  })
}

///|
fn print_usage() -> Unit {
  log_info("Usage: msgtier [config.json]")
}

///|
async fn run_with_config(
  root : @async.TaskGroup[Unit],
  config_path : String,
) -> Unit {
  let config = Config::from_file(config_path)
  init_keypair(config.secret)
  global_config.val = Some(config)
  log_debug(config.to_json().stringify(indent=2))
  log_debug("DEBUG: My Public Key: \{bytes_to_hex(get_public_key())}")
  let id = config.id
  compute_and_store_shared_secret(id, get_public_key())
  for peer_url in config.peers {
    add_known_peer(peer_url)
  }
  init_foreign_network_manager()
  start_listeners(root, config.listeners, id)
  start_http_api(root, config.web_api)
}

///|
fn start_listeners(
  root : @async.TaskGroup[Unit],
  listeners : Array[String],
  id : String,
) -> Unit {
  for listener in listeners {
    start_listener(root, listener, id)
  }
}

///|
fn start_listener(
  root : @async.TaskGroup[Unit],
  listener : String,
  id : String,
) -> Unit {
  match @url.Url::parse(listener) {
    Some(url) => {
      let host = url.get_host()
      let scheme = url.scheme
      let _ : @async.Task[Unit] = root.spawn(async fn() {
        for {
          try {
            log_info("Attempting to listen on \{listener}")
            let transport = create_transport(scheme, host)
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

///|
fn create_transport(scheme : String, host : String) -> &Transport raise {
  match scheme {
    "tcp" => (TcpTransport::new(host) : &Transport)
    "udp" => (UdpTransport::new(host) : &Transport)
    "ws" => (WebSocketTransport::new(host) : &Transport)
    "quic" => (QuicTransport::new(host) : &Transport)
    _ => abort("Unknown protocol: \{scheme}")
  }
}

///|
fn start_http_api(root : @async.TaskGroup[Unit], web_api : String?) -> Unit {
  if web_api is Some(addr) {
    let _ : @async.Task[Unit] = root.spawn(async fn() {
      log_info("HTTP API listening on http://\{addr}")
      start_http_service(addr)
    })
  }
}
