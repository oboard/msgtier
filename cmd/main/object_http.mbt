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
          parts.push(part.to_owned())
        }
        if parts.length() != 2 {
          None
        } else {
          let start_str = parts[0]
          let end_str = parts[1]
          let start_opt : Result[Int, _] = Ok(@string.parse_int(start_str)) catch {
            e => Err(e)
          }
          let end_opt : Result[Int, _] = Ok(@string.parse_int(end_str)) catch {
            e => Err(e)
          }
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
