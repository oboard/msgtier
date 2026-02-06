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

        // Initialize known peers from config
        for peer_url in config.peers {
          add_known_peer(peer_url.to_string())
        }

        // Don't pre-create peers - they will be created when hello messages arrive
        for listener in config.listeners {
          let host = listener.get_host()
          let scheme = listener.scheme
          println("Listening on \{listener}")
          let transport = match scheme {
            "tcp" => (TcpTransport::new(host) : &Transport)
            "udp" => (UdpTransport::new(host) : &Transport)
            "ws" => (WebSocketTransport::new(host) : &Transport)
            "quic" => (QuicTransport::new(host) : &Transport)
            _ => abort("Unknown protocol: \{scheme}")
          }
          root.spawn(fn() { start_listener_service(root, transport, id) })
          |> ignore
        }
        if config.web_api is Some(addr) {
          println("HTTP API listening on http://\{addr}")
          start_http_service(addr, config)
        }
        // 等待所有任务完成
        // for task in tasks {
        //   task.wait()
        // }
      }
      _ => println("MsgTier 0.1")
    }
  })
}
