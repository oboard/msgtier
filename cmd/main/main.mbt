///|
const VERSION = "0.1.0"

///|
let global_config : Ref[Config?] = Ref::new(None)

///|
async fn main {
  // Initialize X25519 key pair
  // init_keypair()
  @async.with_task_group(async fn(root) {
    let args = @env.args()[1:]
    match args {
      [config] => {
        let config = Config::from_file(config)

        // Initialize X25519 key pair from config
        init_keypair(config.secret)

        // Store config globally for access by listeners
        global_config.val = Some(config)
        log_debug(config.to_json().stringify(indent=2))
        log_debug("DEBUG: My Public Key: \{bytes_to_hex(get_public_key())}")
        let id = config.id

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

        // Initialize TCP proxies
        // init_tcp_proxies(root, config) |> ignore

        // 等待所有任务完成
        // for task in tasks {
        //   task.wait()
        // }
      }
      _ => log_info("MsgTier 0.1")
    }
  })
}
