///|
let http_control_body_limit : Int = 1048576

///|
suberror HttpBodyTooLarge derive(Debug)

///|
/// Control requests remain bounded. Object uploads use the network reader
/// directly instead of mocket's native listener, which buffers and caps every
/// body before dispatch (including readers consumed by a streaming handler).
async fn read_http_control_body(reader : &@io.Reader, limit : Int) -> Bytes {
  let body = Buffer()
  let chunk = FixedArray::make(8192, b'\x00')
  for total = 0 {
    let n = reader.read(chunk)
    if n == 0 {
      return body.to_bytes()
    }
    if n > limit - total {
      raise HttpBodyTooLarge
    }
    body.write_bytes(chunk.unsafe_reinterpret_as_bytes()[:n])
    continue total + n
  }
}

///|
async fn handle_object_upload(reader : &@io.Reader) -> @mocket.HttpResponse {
  handle_object_upload_in_dir(get_upload_dir(), reader)
}

///|
async fn handle_object_upload_in_dir(
  directory : String,
  reader : &@io.Reader,
) -> @mocket.HttpResponse {
  try {
    let id = @nanoid.nanoid().unwrap_or(@env.now().to_string())
    save_object_in_dir(directory, id, reader)
    @mocket.HttpResponse(OK).body(({ "id": id.to_json() } : Json))
  } catch {
    ObjectUploadReadError(message) =>
      json_error(BadRequest, "invalid_upload_body", message)
    @async.TimeoutError =>
      json_error(
        RequestTimeout,
        "upload_timeout",
        "Upload stalled for 60 seconds",
      )
    err => {
      log_warn("Object upload failed: \{err}")
      json_error(InternalServerError, "object_upload_failed", "\{err}")
    }
  }
}

///|
fn http_method_name(method_ : @http.RequestMethod) -> String {
  match method_ {
    Get => "GET"
    Head => "HEAD"
    Post => "POST"
    Put => "PUT"
    Delete => "DELETE"
    Connect => "CONNECT"
    Options => "OPTIONS"
    Trace => "TRACE"
    Patch => "PATCH"
  }
}

///|
fn http_request_path(target : String) -> String {
  match split_once(target, "?") {
    Some((path, _)) => path
    None => target
  }
}

///|
async fn send_http_response(
  conn : @http.ServerConnection,
  request : @http.Request,
  response : @mocket.HttpResponse,
) -> Unit {
  let headers : Map[@http.CaseInsensitiveString, String] = Map([])
  for name, value in response.headers {
    // Header values may include user-provided filenames.
    headers[name] = value
      .to_owned()
      .replace(old="\r", new="")
      .replace(old="\n", new="")
  }
  conn.send_response(
    response.status_code.to_int(),
    "OK",
    extra_headers=headers,
    cookies=response.cookies,
  )
  if request.meth != Head {
    if response.body is Some(body) {
      body.output(conn)
    }
  }
  conn.end_response()
}

///|
async fn serve_http_request(
  app : @mocket.App,
  request : @http.Request,
  reader : &@io.Reader,
  conn : @http.ServerConnection,
  upload : async (&@io.Reader) -> @mocket.HttpResponse,
) -> Unit {
  let path = http_request_path(request.path)
  if request.headers.get("upgrade").map(s => s.to_lower()) == Some("websocket") {
    serve_http_websocket(app, path, request, conn)
    return
  }
  let is_upload = request.meth == Post && path == "/api/object"
  let response = if is_upload {
    upload(reader)
  } else {
    try {
      let length = request.headers
        .get("content-length")
        .map(s => @string.parse_int64(s) catch { _ => 0L })
        .unwrap_or(0L)
      if length > http_control_body_limit.to_int64() {
        raise HttpBodyTooLarge
      }
      let body = @async.with_timeout(30000, () => {
        read_http_control_body(reader, http_control_body_limit)
      })
      let headers : Map[@http.CaseInsensitiveString, StringView] = Map([])
      for name, value in request.headers {
        headers[name] = value[:]
      }
      @mocket.dispatch_http(
        app,
        http_method_name(request.meth),
        request.path,
        headers,
        body,
      )
    } catch {
      HttpBodyTooLarge =>
        json_error(
          RequestEntityTooLarge,
          "body_too_large",
          "Request body exceeds 1 MiB",
        )
      err => json_error(BadRequest, "invalid_request_body", "\{err}")
    }
  }
  // Do not drain an unread, rejected body or reinterpret it as another request.
  let close = response.status_code.to_int() >= 400 ||
    request.headers.get("connection").map(s => s.to_lower()) == Some("close")
  if close {
    response.headers["Connection"] = "close"
  }
  send_http_response(conn, request, response)
  if close {
    conn.close()
  }
}

///|
async fn listen_http_service(app : @mocket.App, address : String) -> Unit {
  let address = if address.has_prefix(":") {
    "0.0.0.0" + address
  } else {
    address
  }
  let server = @http.Server(@socket.Addr::parse(address), reuse_addr=true)
  defer server.close()
  server.run_forever(
    (request, reader, conn) => {
      serve_http_request(app, request, reader, conn, handle_object_upload)
    },
    max_connections=128,
  )
}
