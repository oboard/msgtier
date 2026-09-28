///|
struct ObjectFileSlice {
  path : String
  offset : Int64
  length : Int64
}

///|
struct ObjectDownloadPlan {
  status : Int
  headers : Map[String, String]
  offset : Int64
  length : Int64
}

///|
enum ObjectRange {
  Whole
  Partial(Int64, Int64)
  Unsatisfiable
} derive(Debug, Eq)

///|
fn object_header(headers : Map[String, String], name : String) -> String? {
  for key, value in headers {
    if key.to_lower() == name { return Some(value) }
  }
  None
}

///|
fn parse_object_decimal(value : String) -> Int64? {
  if value.is_empty() { return None }
  for char in value {
    if char < '0' || char > '9' { return None }
  }
  Some(@string.parse_int64(value)) catch { _ => None }
}

///|
fn object_range(headers : Map[String, String], total : Int64) -> ObjectRange {
  let raw = match object_header(headers, "range") {
    Some(raw) if raw.has_prefix("bytes=") => raw[6:].to_owned()
    _ => return Whole
  }
  let (start_text, end_text) = match split_once(raw, "-") {
    Some(parts) => parts
    None => return Whole
  }
  if start_text == "" {
    let suffix = match parse_object_decimal(end_text) {
      Some(suffix) => suffix
      None => return Whole
    }
    if suffix == 0L || total == 0L { return Unsatisfiable }
    let start = if suffix >= total { 0L } else { total - suffix }
    return Partial(start, total - 1L)
  }
  let start = match parse_object_decimal(start_text) {
    Some(start) => start
    None => return Whole
  }
  let end = if end_text == "" {
    total - 1L
  } else {
    match parse_object_decimal(end_text) {
      Some(end) => end
      None => return Whole
    }
  }
  if start >= total || start > end { return Unsatisfiable }
  Partial(start, if end >= total { total - 1L } else { end })
}

///|
fn object_download_plan(
  total : Int64,
  filename : String?,
  request_headers : Map[String, String],
) -> ObjectDownloadPlan {
  let headers : Map[String, String] = {
    "Content-Type": "application/octet-stream",
    "Accept-Ranges": "bytes",
  }
  if filename is Some(filename) {
    let safe = filename.replace(old="\r", new="").replace(old="\n", new="")
      .replace(old="\"", new="_").replace(old="\\", new="_")
    headers["Content-Disposition"] = "attachment; filename=\"\{safe}\"; filename*=UTF-8''\{@mocket.url_encode(safe)}"
  }
  let (status, offset, length) = match object_range(request_headers, total) {
    Whole => (200, 0L, total)
    Partial(start, end) => {
      headers["Content-Range"] = "bytes \{start}-\{end}/\{total}"
      (206, start, end - start + 1L)
    }
    Unsatisfiable => {
      headers["Content-Range"] = "bytes */\{total}"
      (416, 0L, 0L)
    }
  }
  headers["Content-Length"] = length.to_string()
  { status, headers, offset, length }
}

///|
impl @mocket.Responder for ObjectFileSlice with fn options(_self, _response) {
  ()
}

///|
impl @mocket.Responder for ObjectFileSlice with fn output(self, writer) {
  let file = @fs.open(self.path, mode=ReadOnly)
  defer file.close()
  let buffer = FixedArray::make(65536, b'\x00')
  for sent = 0L; sent < self.length; {
    let remaining = self.length - sent
    let size = if remaining < 65536L { remaining.to_int() } else { 65536 }
    let n = file.read_at(buffer, position=self.offset + sent, len=size)
    if n == 0 { fail("object changed during download") }
    writer.write(buffer.unsafe_reinterpret_as_bytes()[:n])
    continue sent + n.to_int64()
  }
}

///|
async fn object_file_response(
  path : String,
  filename : String?,
  headers : Map[String, String],
) -> @mocket.HttpResponse {
  let plan = object_download_plan(@fs.file_size(path), filename, headers)
  let body : ObjectFileSlice = { path, offset: plan.offset, length: plan.length }
  @mocket.HttpResponse(
    @mocket.StatusCode::from_int(plan.status),
    headers=view_map_from_string_map(plan.headers),
    body=body,
  )
}
