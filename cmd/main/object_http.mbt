///|
async fn handle_object_upload(
  _request : @http.Request,
  body : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  let id = @nanoid.nanoid().unwrap_or(@env.now().to_string())
  save_object_from_reader(id, body)

  let m : Json = { "id": id }
  let json_str = m.stringify()

  conn
  ..send_response(200, "OK", extra_headers={
    "Content-Type": "application/json",
  })
  ..write(json_str)
  .end_response()
}

///|
async fn handle_object_registration(
  body : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  let bytes = body.read_all().binary()
  let json_str = @utf8.decode(bytes)
  let json_val = @json.parse(json_str) catch {
    _ => {
      conn.send_response(400, "Bad Request")
      return
    }
  }

  let path = match json_val {
    Object({ "path": String(s), .. }) => s
    _ => ""
  }

  if path == "" {
    conn.send_response(400, "Missing path")
    return
  }

  let id = register_object(path)

  let m = Map::new()
  m["id"] = id.to_json()
  let resp_json = m.to_json().stringify()

  conn
  ..send_response(200, "OK", extra_headers={
    "Content-Type": "application/json",
  })
  ..write(resp_json)
  .end_response()
}

///|
fn parse_range_header(
  headers : Map[String, String],
  total_len : Int,
) -> (Int, Int)? {
  let range = match headers.get("Range") {
    Some(v) => Some(v)
    None => headers.get("range")
  }
  match range {
    Some(r) =>
      if !r.has_prefix("bytes=") || r.length() <= 6 {
        None
      } else {
        let spec = r.replace(old="bytes=", new="")
        let parts = []
        for part in spec.split("-") {
          parts.push(part.to_string())
        }
        if parts.length() != 2 {
          None
        } else {
          let start_str = parts[0]
          let end_str = parts[1]
          let start_opt = try? @strconv.parse_int(start_str)
          let end_opt = try? @strconv.parse_int(end_str)
          match (start_opt, end_opt) {
            (Ok(start), Ok(end)) =>
              if start < 0 {
                None
              } else {
                let start = if start >= total_len { total_len } else { start }
                let end = if end < start { start } else { end }
                let end = if end >= total_len { total_len - 1 } else { end }
                if start >= total_len {
                  None
                } else {
                  Some((start, end))
                }
              }
            (Ok(start), Err(_)) =>
              if start < 0 || start >= total_len {
                None
              } else {
                Some((start, total_len - 1))
              }
            (Err(_), Ok(suffix_len)) =>
              if suffix_len <= 0 || suffix_len > total_len {
                None
              } else {
                Some((total_len - suffix_len, total_len - 1))
              }
            _ => None
          }
        }
      }
    None => None
  }
}

///|
fn build_object_download_response(
  data : Bytes,
  filename : String?,
  request_headers : Map[String, String],
) -> (Int, Map[String, String], Bytes) {
  let headers : Map[String, String] = {
    "Content-Type": "application/octet-stream",
  }
  headers["Accept-Ranges"] = "bytes"
  match filename {
    Some(fname) =>
      headers["Content-Disposition"] = "attachment; filename=\"\{fname}\""
    None => ()
  }
  match parse_range_header(request_headers, data.length()) {
    Some((start, end)) => {
      let end_exclusive = end + 1
      let body = slice_bytes(data, start, end_exclusive)
      headers["Content-Length"] = body.length().to_string()
      headers["Content-Range"] = "bytes \{start}-\{end}/\{data.length()}"
      (206, headers, body)
    }
    None => {
      headers["Content-Length"] = data.length().to_string()
      (200, headers, data)
    }
  }
}

///|
fn parse_range_str(header : String) -> (Int, Int?)? {
  if !header.has_prefix("bytes=") {
    return None
  }
  let s = header[6:]
  let parts = s.split("-").to_array()
  if parts.length() < 1 {
    return None
  }

  try {
    let start_str = parts[0]
    if start_str == "" {
      return None
    }
    let start = @strconv.parse_int(start_str)
    let end = if parts.length() > 1 && parts[1] != "" {
      Some(@strconv.parse_int(parts[1]))
    } else {
      None
    }
    Some((start, end))
  } catch {
    _ => None
  }
}

///|
async fn handle_object_download(
  root : @async.TaskGroup[Unit],
  id : String,
  peer_id : String?,
  filename : String?,
  request_headers : Map[String, String],
  conn : @http.ServerConnection,
) -> Unit {
  let range_header = match request_headers.get("Range") {
    Some(v) => Some(v)
    None => request_headers.get("range")
  }

  match get_object_path(id) {
    Some(path) => {
      let mut response_started = false
      try {
        let file = @fs.open(path, mode=ReadOnly)
        defer file.close()

        let headers : Map[String, String] = {
          "Content-Type": "application/octet-stream",
          "Accept-Ranges": "bytes",
        }
        match filename {
          Some(fname) =>
            headers["Content-Disposition"] = "attachment; filename=\"\{fname}\""
          None => ()
        }

        match range_header {
          Some(rh) =>
            match parse_range_str(rh) {
              Some((start, end_opt)) => {
                let skip_buf = FixedArray::make(4096, b'\x00')
                let mut skipped = 0
                let mut ok = true
                while skipped < start {
                  let remaining_skip = start - skipped
                  let to_read = if remaining_skip < 4096 {
                    remaining_skip
                  } else {
                    4096
                  }

                  let read_buf = if to_read < 4096 {
                    FixedArray::make(to_read, b'\x00')
                  } else {
                    skip_buf
                  }

                  let n = file.read(read_buf) catch { _ => 0 }
                  if n <= 0 {
                    ok = false
                    break
                  }
                  skipped += n
                }

                if ok {
                  let len = match end_opt {
                    Some(end) => end - start + 1
                    None => 2147483647
                  }

                  headers["Content-Range"] = match end_opt {
                    Some(end) => "bytes \{start}-\{end}/*"
                    None => "bytes \{start}-/*"
                  }

                  conn.send_response(
                    206,
                    "Partial Content",
                    extra_headers=headers,
                  )
                  response_started = true

                  let buf = FixedArray::make(4096, b'\x00')
                  let mut remaining = len

                  while remaining > 0 {
                    let to_read = if remaining < 4096 {
                      remaining
                    } else {
                      4096
                    }
                    let read_buf = if to_read < 4096 {
                      FixedArray::make(to_read, b'\x00')
                    } else {
                      buf
                    }

                    let n = file.read(read_buf) catch { _ => 0 }
                    if n <= 0 {
                      break
                    }

                    let chunk_buf = FixedArray::make(n, b'\x00')
                    for i = 0; i < n; i = i + 1 {
                      chunk_buf[i] = read_buf[i]
                    }
                    let chunk = Bytes::from_array(chunk_buf)
                    conn.write(chunk)

                    remaining -= n
                  }

                  conn.end_response()
                  return
                }
              }
              None => ()
            }
          None => ()
        }

        conn.send_response(200, "OK", extra_headers=headers)
        response_started = true
        conn.write_reader(file)
        conn.end_response()
        return
      } catch {
        e => {
          log_warn("handle_object_download error: \{e}")
          if response_started {
            return
          }
        }
      }
    }
    None => ()
  }
  try {
    match get_object(id) {
      Some(data) => {
        let (status_code, headers, body) = build_object_download_response(
          data, filename, request_headers,
        )
        conn
        ..send_response(
          status_code,
          status_text(status_code),
          extra_headers=headers,
        )
        ..write(body)
        .end_response()
      }
      None =>
        match peer_id {
          Some(pid) => {
            log_info("ObjectStore: fetching object id=\{id} from peer=\{pid}")

            let mut path = "/api/object/" + id
            match filename {
              Some(fname) => path = path + "?filename=" + fname
              None => ()
            }
            let forward_headers : Map[String, String] = {}
            match request_headers.get("Range") {
              Some(v) => forward_headers["Range"] = v
              None =>
                match request_headers.get("range") {
                  Some(v) => forward_headers["Range"] = v
                  None => ()
                }
            }
            let timeout_ms = 300000
            let _ = root.spawn_bg(async fn() {
              proxy_http_request_stream(
                pid, "GET", path, forward_headers, b"", timeout_ms, filename, conn,
              )
            })
            return
          }
          None =>
            conn
            ..send_response(404, "Not Found", extra_headers={})
            ..write("Object not found")
            .end_response()
        }
    }
  } catch {
    e => log_warn("handle_object_download fallback error: \{e}")
  }
}
