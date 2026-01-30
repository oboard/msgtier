///|
const VERSION = "0.1.0"

///|
let global_config : Ref[Config?] = Ref::new(None)

///|
let global_reconnect_manager : Ref[ReconnectManager] = Ref::new(
  ReconnectManager::new(),
)

///|
async fn main {
  @async.with_task_group(fn(root) {
    let args = @env.args()[1:]
    match args {
      [config] => {
        let config = Config::from_file(config)
        println(config.to_json().stringify(indent=2))
        let id = config.id
        for addr in config.listeners {
          let addr = addr.get_host()
          println("Listening on \{addr}")
          ignore(
            root.spawn(fn() { listen_udp(root, @socket.Addr::parse(addr), id) }),
          )
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
