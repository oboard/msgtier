///|
struct ObjectPeerDownload {
  offset : Int64
  length : Int64
  fetch : async (Int64, Int) -> Bytes
}

///|
impl @mocket.Responder for ObjectPeerDownload with fn options(_self, _response) {
  ()
}

///|
/// Fetch the next bounded range only after the previous range has been written
/// to the browser. The request tracker never has to assemble a whole file.
impl @mocket.Responder for ObjectPeerDownload with fn output(self, writer) {
  for sent = 0L; sent < self.length; {
    let remaining = self.length - sent
    let size = if remaining < 1048576L { remaining.to_int() } else { 1048576 }
    let chunk = (self.fetch)(self.offset + sent, size)
    if chunk.length() != size { fail("incomplete object range from peer") }
    writer.write(chunk)
    continue sent + size.to_int64()
  }
}

///|
async fn fetch_object_peer_range(
  peer : String,
  path : String,
  start : Int64,
  length : Int,
  total : Int64,
) -> Bytes {
  let end = start + length.to_int64() - 1L
  match proxy_http_request(
    peer, "GET", path, { "Range": "bytes=\{start}-\{end}" }, b"", 30000,
  ) {
    Some((206, headers, body)) => {
      if object_header(headers, "content-range") != Some("bytes \{start}-\{end}/\{total}") ||
        body.length() != length {
        fail("invalid object range from peer")
      }
      body
    }
    Some((status, _, _)) => fail("peer object download returned HTTP \{status}")
    None => fail("peer object download timed out")
  }
}

///|
async fn object_peer_response(
  peer : String,
  id : String,
  filename : String?,
  headers : Map[String, String],
) -> @mocket.HttpResponse {
  let path = "/api/object/" + @mocket.url_encode(id)
  let (status, metadata, _) = match proxy_http_request(peer, "HEAD", path, {}, b"", 30000) {
    Some(result) => result
    None => return json_error(GatewayTimeout, "object_peer_timeout", "Timeout fetching object from peer")
  }
  if status != 200 {
    let code = if status == 404 { @mocket.NotFound } else { @mocket.BadGateway }
    return json_error(code, "object_peer_failed", "Peer returned HTTP \{status}")
  }
  let total = match object_header(metadata, "content-length") {
    Some(value) => parse_object_decimal(value)
    None => None
  }
  let total = match total {
    Some(total) => total
    None => return json_error(BadGateway, "object_peer_invalid", "Peer did not provide the object size")
  }
  let plan = object_download_plan(total, filename, headers)
  let body : ObjectPeerDownload = {
    offset: plan.offset,
    length: plan.length,
    fetch: (start, length) => fetch_object_peer_range(peer, path, start, length, total),
  }
  @mocket.HttpResponse(
    @mocket.StatusCode::from_int(plan.status),
    headers=view_map_from_string_map(plan.headers),
    body=body,
  )
}
