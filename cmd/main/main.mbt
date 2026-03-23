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
        log_info("Version: \{app_state.version}")
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
  app_state.root = Some(root)
  set_config(config)
  reset_bench_trace()
  start_bench_trace_flusher(root)
  log_debug(config.to_json().stringify(indent=2))
  let id = config.id
  for peer_url in config.peers {
    add_known_peer(peer_url)
  }
  ensure_managed_openclaw_plugin()
  init_openclaw_registry(root)
  init_port_forward_registry(root)
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
        for ;; {
          try {
            log_info("Attempting to listen on \{listener}")
            if scheme == "udp" {
              probe_listener_stun(listener, host)
            }
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
      start_http_service(root, addr)
    })
  }
}
