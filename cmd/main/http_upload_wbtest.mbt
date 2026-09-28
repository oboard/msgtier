///|
async fn with_object_http_test_server(
  run : async (String, String, Ref[Int]) -> Unit,
) -> Unit {
  let root = @fs.tmpdir(prefix="msgtier-upload-http-test-")
  defer @fs.rmdir(root, recursive=true)
  let directory = root + "/nested/uploads"
  let completed = Ref(0)
  let app = @mocket.App()
  app.post("/api/echo", event => {
    let bytes : Bytes = event.req.body()
    @mocket.HttpResponse(OK, body=bytes)
  })
  app.get("/api/object/:id", event => {
    let id = event.params["id"].to_owned()
    object_file_response(
      directory + "/" + id,
      parse_query_map(request_query(event.req)).get("filename"),
      owned_headers(event.req.headers),
    )
  })
  app.ws("/api/ws", event => {
    match event {
      Message(peer, Text(text)) => peer.text(text)
      _ => ()
    }
  })
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_timeout(15000, () => {
    @async.with_task_group(group => {
      group.spawn_bg(no_wait=true, () => {
        server.run_forever((request, reader, conn) => {
          serve_http_request(app, request, reader, conn, reader => {
            defer {
              completed.val += 1
            }
            handle_object_upload_in_dir(directory, reader)
          })
        })
      })
      run(server.addr.to_string(), directory, completed)
    })
  })
}

///|
fn uploaded_object_id(body : String) -> String raise {
  guard @json.parse(body) is { "id": String(id), .. } else {
    fail("invalid upload response: \{body}")
  }
  id
}

///|
async test "HTTP uploads cross 1 MiB boundary without corrupting binary files" {
  with_object_http_test_server((address, directory, completed) => {
    for size in [0, 1048576, 1048577, 4194317] {
      let bytes = FixedArray::makei(size, i => (i % 251).to_byte()).unsafe_reinterpret_as_bytes()
      let (response, body) = @http.request(
        "http://" + address + "/api/object",
        Post,
        { "Content-Type": "application/octet-stream" },
        bytes,
      )
      assert_eq(response.code, 200)
      let id = uploaded_object_id(body.text())
      assert_eq(@fs.read_file(directory + "/" + id).binary(), bytes)
      let (download, downloaded) = @http.get(
        "http://" + address + "/api/object/" + id + "?filename=test%20file.bin",
      )
      assert_eq(download.code, 200)
      assert_eq(downloaded.binary(), bytes)
      assert_true(
        download.headers["Content-Disposition"].contains("test file.bin"),
      )
    }
    inspect(completed.val, content="4")
  })
}

///|
async test "HTTP chunked upload without Content-Length remains complete" {
  with_object_http_test_server((address, directory, _) => {
    let client = @http.Client("http://" + address)
    defer client.close()
    client.request(Post, "/api/object", extra_headers={
      "Content-Type": "application/octet-stream",
    })
    let bytes = FixedArray::makei(1048593, i => (i % 251).to_byte()).unsafe_reinterpret_as_bytes()
    client.write(bytes[:13])
    client.write(bytes[13:])
    let response = client.end_request()
    inspect(response.code, content="200")
    let id = uploaded_object_id(client.read_all().text())
    inspect(
      @fs.read_file(directory + "/" + id).binary() == bytes,
      content="true",
    )
  })
}

///|
async test "HTTP upload starts writing before entire request arrives" {
  with_object_http_test_server((address, directory, _) => {
    let conn = @socket.Tcp::connect(@socket.Addr::parse(address))
    defer conn.close()
    let bytes = FixedArray::make(65536, b'x').unsafe_reinterpret_as_bytes()
    conn.write(
      "POST /api/object HTTP/1.1\r\nHost: localhost\r\nContent-Length: 131072\r\nConnection: close\r\n\r\n",
    )
    conn.write(bytes)
    for ;; {
      let names = @fs.readdir(directory, include_hidden=true) catch { _ => [] }
      let written = if names.length() == 1 {
        @fs.file_size(directory + "/" + names[0])
      } else {
        0L
      }
      if written == 65536L {
        break
      }
      @async.sleep(5)
    }
    conn.write(bytes)
    let headers = conn.read_until("\r\n\r\n").unwrap_or("")
    inspect(headers.has_prefix("HTTP/1.1 200"), content="true")
    let names = @fs.readdir(directory)
    inspect(names.length(), content="1")
    inspect(@fs.file_size(directory + "/" + names[0]), content="131072")
  })
}

///|
async test "aborted HTTP upload removes partial file rather than publishing success" {
  with_object_http_test_server((address, directory, completed) => {
    let conn = @socket.Tcp::connect(@socket.Addr::parse(address))
    conn.write(
      "POST /api/object HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10000\r\n\r\npartial",
    )
    conn.close()
    while completed.val == 0 {
      @async.sleep(5)
    }
    inspect(
      @fs.readdir(directory, include_hidden=true).is_empty(),
      content="true",
    )
  })
}

///|
async test "control APIs keep the 1 MiB body limit and reject without draining" {
  with_object_http_test_server((address, _, _) => {
    let conn = @socket.Tcp::connect(@socket.Addr::parse(address))
    defer conn.close()
    conn.write(
      "POST /api/echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1048577\r\n\r\n",
    )
    let headers = conn.read_until("\r\n\r\n").unwrap_or("")
    inspect(headers.has_prefix("HTTP/1.1 413"), content="true")
    inspect(headers.to_lower().contains("connection: close"), content="true")
    let (response, body) = @http.request(
      "http://" + address + "/api/echo",
      Post,
      {},
      b"healthy",
    )
    inspect(response.code, content="200")
    inspect(body.text(), content="healthy")
  })
}

///|
async test "streaming HTTP listener keeps WebSocket frame delivery and cleanup" {
  with_object_http_test_server((address, _, _) => {
    for _ in 0..<4 {
      let ws = @websocket.connect("ws://" + address + "/api/ws")
      defer ws.close()
      ws.send_text("upload-chat-regression")
      let message = ws.recv()
      assert_eq(message.read_all().text(), "upload-chat-regression")
      ws.close()
    }
    let (response, body) = @http.request(
      "http://" + address + "/api/echo",
      Post,
      {},
      b"still healthy",
    )
    inspect(response.code, content="200")
    inspect(body.text(), content="still healthy")
  })
}

///|
async test "malformed chunked upload reports a body error and cleans temporary data" {
  with_object_http_test_server((address, directory, completed) => {
    let conn = @socket.Tcp::connect(@socket.Addr::parse(address))
    defer conn.close()
    conn.write(
      "POST /api/object HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n7\r\npartial\r\nnot-a-size\r\n",
    )
    let headers = conn.read_until("\r\n\r\n").unwrap_or("")
    inspect(headers.has_prefix("HTTP/1.1 400"), content="true")
    inspect(completed.val, content="1")
    inspect(
      @fs.readdir(directory, include_hidden=true).is_empty(),
      content="true",
    )
  })
}

///|
async test "control body limit also applies without Content-Length" {
  let bytes = FixedArray::make(65, b'x').unsafe_reinterpret_as_bytes()
  try
    read_http_control_body(@io.MemoryReader(writer => writer.write(bytes)), 64)
  catch {
    HttpBodyTooLarge => ()
    err => fail("unexpected error: \{err}")
  } noraise {
    _ => fail("expected streamed body to exceed limit")
  }
}
