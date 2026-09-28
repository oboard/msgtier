///|
test "mocket query field preserves peer and decodes attachment filename" {
  let req : @mocket.HttpRequest = {
    http_method: "GET",
    url: "/api/object/example",
    query: "peer=node%2Btwo&filename=%E6%B5%8B%E8%AF%95+file%2B.bin",
    headers: {},
    reader: @io.MemoryReader(_ => ()),
  }
  let query = parse_query_map(request_query(req))
  inspect(query["peer"], content="node+two")
  inspect(query["filename"], content="测试 file+.bin")
}

///|
test "object range handles open ended ranges suffixes and case insensitive headers" {
  debug_inspect(
    object_range({ "rAnGe": "bytes=3-6" }, 10L),
    content="Partial(3, 6)",
  )
  debug_inspect(
    object_range({ "Range": "bytes=3-" }, 10L),
    content="Partial(3, 9)",
  )
  debug_inspect(
    object_range({ "Range": "bytes=-3" }, 10L),
    content="Partial(7, 9)",
  )
  debug_inspect(
    object_range({ "Range": "bytes=-30" }, 10L),
    content="Partial(0, 9)",
  )
  debug_inspect(
    object_range({ "Range": "bytes=3-30" }, 10L),
    content="Partial(3, 9)",
  )
}

///|
test "object range rejects unsatisfiable ranges and ignores malformed ranges" {
  debug_inspect(
    object_range({ "Range": "bytes=10-" }, 10L),
    content="Unsatisfiable",
  )
  debug_inspect(
    object_range({ "Range": "bytes=5-3" }, 10L),
    content="Unsatisfiable",
  )
  debug_inspect(
    object_range({ "Range": "bytes=-0" }, 10L),
    content="Unsatisfiable",
  )
  debug_inspect(
    object_range({ "Range": "bytes=0-" }, 0L),
    content="Unsatisfiable",
  )
  debug_inspect(
    object_range({ "Range": "bytes=0-1,3-4" }, 10L),
    content="Whole",
  )
  debug_inspect(
    object_range({ "Range": "bytes=1_bad-2" }, 10L),
    content="Whole",
  )
}

///|
test "object metadata supports sizes and offsets above 2 GiB" {
  let plan = object_download_plan(4294967296L, None, {
    "Range": "bytes=2147483648-2147483650",
  })
  inspect(plan.status, content="206")
  inspect(plan.offset, content="2147483648")
  inspect(plan.length, content="3")
  inspect(
    plan.headers["Content-Range"],
    content="bytes 2147483648-2147483650/4294967296",
  )
}

///|
test "empty and unsatisfiable downloads have correct content lengths" {
  let empty = object_download_plan(0L, None, {})
  inspect(empty.status, content="200")
  inspect(empty.headers["Content-Length"], content="0")
  let invalid = object_download_plan(4L, None, { "Range": "bytes=9-" })
  inspect(invalid.status, content="416")
  inspect(invalid.headers["Content-Length"], content="0")
  inspect(invalid.headers["Content-Range"], content="bytes */4")
}

///|
test "download filenames retain UTF8 and cannot inject response headers" {
  let plan = object_download_plan(3L, Some("测试\r\n\".bin"), {})
  let disposition = plan.headers["Content-Disposition"]
  inspect(
    disposition.contains("\r") || disposition.contains("\n"),
    content="false",
  )
  inspect(
    disposition.contains("filename*=UTF-8''%E6%B5%8B%E8%AF%95_.bin"),
    content="true",
  )
}

///|
async test "local file responder streams exact ranges across buffer boundaries" {
  let dir = @fs.tmpdir(prefix="msgtier-object-http-test-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/file"
  let bytes = FixedArray::makei(200003, i => (i % 251).to_byte()).unsafe_reinterpret_as_bytes()
  @fs.write_file(path, bytes)
  let response = object_file_response(path, Some("test.bin"), {
    "Range": "bytes=65535-180001",
  })
  inspect(response.status_code.to_int(), content="206")
  let received : Bytes = response.read_body()
  inspect(received == bytes[65535:180002].to_owned(), content="true")
  inspect(
    response.headers.get("Content-Length").map(s => s.to_owned()).unwrap_or(""),
    content="114467",
  )
}

///|
async test "peer internal object API supplies HEAD metadata and honours range offsets" {
  let dir = @fs.tmpdir(prefix="msgtier-object-http-test-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/file"
  @fs.write_file(path, b"0123456789")
  let id = register_object(path)
  defer object_store_state.store.objects.remove(id)
  let url = "/api/object/" + id + "?filename=test%20file.bin"
  let (status, headers, body) = handle_internal_http_request(
    "HEAD",
    url,
    {},
    b"",
  )
  inspect(status, content="200")
  inspect(headers["Content-Length"], content="10")
  inspect(
    headers["Content-Disposition"].contains("test file.bin"),
    content="true",
  )
  inspect(body is Bytes(b""), content="true")
  let (range_status, range_headers, range_body) = handle_internal_http_request(
    "GET",
    url,
    { "Range": "bytes=3-6" },
    b"",
  )
  inspect(range_status, content="206")
  inspect(range_headers["Content-Range"], content="bytes 3-6/10")
  guard range_body is File(slice) else { fail("expected file range") }
  let response = @mocket.HttpResponse(PartialContent, body=slice)
  let data : Bytes = response.read_body()
  inspect(data == b"3456", content="true")
}

///|
async test "peer internal empty file returns a response without zero chunk timeout" {
  let dir = @fs.tmpdir(prefix="msgtier-object-http-test-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/empty"
  @fs.write_file(path, b"")
  let id = register_object(path)
  defer object_store_state.store.objects.remove(id)
  let (status, headers, body) = handle_internal_http_request(
    "GET",
    "/api/object/" + id,
    {},
    b"",
  )
  inspect(status, content="200")
  inspect(headers["Content-Length"], content="0")
  inspect(body is Bytes(b""), content="true")
}

///|
async test "peer download uses bounded sequential ranges and preserves large offsets" {
  let requests : Array[(Int64, Int)] = []
  let download : ObjectPeerDownload = {
    offset: 2147483648L,
    length: 2097155L,
    fetch: (start, size) => {
      requests.push((start, size))
      @async.pause()
      FixedArray::make(size, b'x').unsafe_reinterpret_as_bytes()
    },
  }
  let response = @mocket.HttpResponse(OK, body=download)
  let data : Bytes = response.read_body()
  inspect(data.length(), content="2097155")
  debug_inspect(
    requests,
    content="[(2147483648, 1048576), (2148532224, 1048576), (2149580800, 3)]",
  )
}

///|
async test "peer download stops on a truncated range instead of returning corrupt success" {
  let calls = Ref(0)
  let download : ObjectPeerDownload = {
    offset: 0L,
    length: 2000000L,
    fetch: (_start, _size) => {
      calls.val += 1
      @async.pause()
      b"short"
    },
  }
  let response = @mocket.HttpResponse(OK, body=download)
  try {
    let _ : Bytes = response.read_body()
  } catch {
    _ => ()
  } noraise {
    _ => fail("truncated peer range must fail")
  }
  inspect(calls.val, content="1")
}
