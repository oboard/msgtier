///|
const VERSION = "0.1.0"

///|
let global_config : Ref[Config?] = Ref::new(None)

///|
async fn main {
  // Initialize X25519 key pair
  init_keypair()
  @async.with_task_group(fn(root) {
    let args = @env.args()[1:]
    match args {
      [config] => {
        let config = Config::from_file(config)
        println(config.to_json().stringify(indent=2))
        let id = config.id

        // Store config globally for access by listeners
        global_config.val = Some(config)
        set_log_level_from_config(config)

        // Initialize known peers from config
        for peer_url in config.peers {
          add_known_peer(peer_url)
        }

        // Don't pre-create peers - they will be created when hello messages arrive
        for listener in config.listeners {
          match @url.Url::parse(listener) {
            Some(url) => {
              let host = url.get_host()
              let scheme = url.scheme
              let _ : @async.Task[Unit] = root.spawn(fn() {
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
          let _ : @async.Task[Unit] = root.spawn(fn() {
            log_info("HTTP API listening on http://\{addr}")
            start_http_service(addr, config)
          })

        }

        // Initialize TCP proxies
        init_tcp_proxies(root, config) |> ignore

        // 等待所有任务完成
        // for task in tasks {
        //   task.wait()
        // }
      }
      _ => println("MsgTier 0.1")
    }
  })
}
