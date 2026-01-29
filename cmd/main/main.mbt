///|
async fn main {
  @async.with_task_group(fn(root) {
    let args = @env.args()[1:]
    match args {
      [config] => {
        let config = Config::from_file(config)
        println(config.to_json().stringify(indent=2))
        let tasks = []
        for addr in config.listeners {
          let addr = addr.get_host()
          println("Listening on \{addr}")
          let task = root.spawn(fn() {
            listen_udp(root, @socket.Addr::parse(addr))
          })
          tasks.push(task)
        }
        // 等待所有任务完成
        for task in tasks {
          task.wait()
        }
      }
      _ => println("MsgTier 0.1")
    }
  })
}
