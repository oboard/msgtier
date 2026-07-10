///|
async fn main {
  @signal.set_global_cancellation_signals([@signal.SIGTERM, @signal.SIGINT])
  @async.with_task_group(root => {
    let cmd = @argparse.Command(
      "msgtier",
      about="Decentralized P2P messaging network",
      version=app_state.version,
      positionals=[
        PositionArg(
          "config",
          about="Path to config JSON",
          num_args=@argparse.ValueRange::single(),
        ),
      ],
    )
    // On parse failure argparse already prints the error + usage to stdout;
    // we swallow the raise and return without additional logging.
    let matches = cmd.parse(argv=@env.args()[1:]) catch { _ => return }
    let config_path = matches.values.get("config").unwrap_or([])
    if config_path.is_empty() {
      log_info(cmd.render_help())
      return
    }
    run_with_config(root, config_path[0])
  })
}

///|
async fn run_with_config(
  root : @async.TaskGroup[Unit],
  config_path : String,
) -> Unit {
  root.add_defer(fn() { log_info("node shutting down") })
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
  init_port_forward_registry(root)
  root.spawn_bg(async fn() { init_port_mapping_store(root) })
  init_port_scanner(root)
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
      let _ : @async.Task[Unit] = root.spawn(() => {
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
async fn create_transport(scheme : String, host : String) -> &Transport {
  match scheme {
    "tcp" => (TcpTransport(host) : &Transport)
    "udp" => (UdpTransport(host) : &Transport)
    "ws" => (WebSocketTransport(host) : &Transport)
    "quic" => (QuicTransport(host) : &Transport)
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
