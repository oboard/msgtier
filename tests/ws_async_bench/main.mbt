///|
let default_port : Int = 18120

///|
let default_size_mb : Int = 16

///|
let default_chunk_kb : Int = 1024

///|
fn parse_flag_int(
  args : ArrayView[String],
  flag : String,
  fallback : Int,
) -> Int {
  for i = 0; i + 1 < args.length(); i = i + 1 {
    if args[i] == flag {
      let parsed = @string.parse_int(args[i + 1]) catch { _ => fallback }
      if parsed > 0 {
        return parsed
      }
      return fallback
    }
  }
  fallback
}

///|
fn make_payload(size : Int) -> Bytes {
  let arr = FixedArray::make(size, b'a')
  Bytes::from_array(arr)
}

///|
fn mib_per_sec(total_bytes : Int, elapsed_ms : UInt64) -> Double {
  if elapsed_ms == 0UL {
    return 0.0
  }
  let mib = total_bytes.to_double() / 1024.0 / 1024.0
  let seconds = elapsed_ms.to_double() / 1000.0
  mib / seconds
}

///|
async fn run_download_bench(port : Int, total_bytes : Int) -> Double {
  let ws = @websocket.connect("ws://127.0.0.1:\{port}/download")
  defer ws.close()
  let mut received = 0
  let start = @env.now()
  for ;; {
    let msg = ws.recv()
    match msg.kind {
      Binary => {
        received = received + msg.read_all().binary().length()
        if received >= total_bytes {
          break ()
        }
      }
      Text => ignore(msg.read_all())
    }
  }
  mib_per_sec(received, @env.now() - start)
}

///|
async fn run_upload_bench(
  port : Int,
  total_bytes : Int,
  chunk_bytes : Int,
) -> Double {
  let ws = @websocket.connect("ws://127.0.0.1:\{port}/upload")
  defer ws.close()
  let payload = make_payload(chunk_bytes)
  let start = @env.now()
  let mut sent = 0
  while sent < total_bytes {
    let size = if sent + chunk_bytes > total_bytes {
      total_bytes - sent
    } else {
      chunk_bytes
    }
    let chunk = if size == chunk_bytes {
      payload
    } else {
      let arr = FixedArray::make(size, b'a')
      Bytes::from_array(arr)
    }
    ws.send_binary(chunk)
    sent = sent + size
  }
  let _ = ws.recv()
  mib_per_sec(total_bytes, @env.now() - start)
}

///|
async fn handle_download(
  ws : @websocket.Conn,
  total_bytes : Int,
  chunk_bytes : Int,
) -> Unit {
  let payload = make_payload(chunk_bytes)
  let mut sent = 0
  while sent < total_bytes {
    let size = if sent + chunk_bytes > total_bytes {
      total_bytes - sent
    } else {
      chunk_bytes
    }
    let chunk = if size == chunk_bytes {
      payload
    } else {
      let arr = FixedArray::make(size, b'a')
      Bytes::from_array(arr)
    }
    ws.send_binary(chunk)
    sent = sent + size
  }
}

///|
async fn handle_upload(ws : @websocket.Conn, total_bytes : Int) -> Unit {
  let mut received = 0
  while received < total_bytes {
    let msg = ws.recv()
    match msg.kind {
      Binary => received = received + msg.read_all().binary().length()
      Text => ignore(msg.read_all())
    }
  }
  ws.send_binary(b"ok")
}

///|
async fn main {
  let args = @env.args()[1:]
  let port = parse_flag_int(args, "--port", default_port)
  let size_mb = parse_flag_int(args, "--size-mb", default_size_mb)
  let chunk_kb = parse_flag_int(args, "--chunk-kb", default_chunk_kb)
  let total_bytes = size_mb * 1024 * 1024
  let chunk_bytes = chunk_kb * 1024
  let addr = @socket.Addr::parse("127.0.0.1:\{port}") catch {
    e => abort(e.to_string())
  }
  let server = @http.Server::new(addr, reuse_addr=true)

  @async.with_task_group(async fn(root) {
    root.spawn_bg(async fn() {
      server.run_forever(async fn(request, _resp, conn) {
        let ws = @websocket.from_http_server(request, conn)
        defer ws.close()
        match request.path {
          "/download" => handle_download(ws, total_bytes, chunk_bytes)
          "/upload" => handle_upload(ws, total_bytes)
          _ => ()
        }
      })
    })

    @async.sleep(100)

    let download = run_download_bench(port, total_bytes)
    println("moonbit_async_ws_download=\{download} MiB/s")

    let upload = run_upload_bench(port, total_bytes, chunk_bytes)
    println("moonbit_async_ws_upload=\{upload} MiB/s")

    @sys.exit(0)
  })
}
