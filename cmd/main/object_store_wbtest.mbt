///|
async test "object upload creates nested searchable directories and keeps binary bytes" {
  let root = @fs.tmpdir(prefix="msgtier-object-test-")
  defer @fs.rmdir(root, recursive=true)
  let dir = root + "/nested/uploads"
  let bytes = FixedArray::makei(1048577, i => (i % 251).to_byte()).unsafe_reinterpret_as_bytes()
  save_object_in_dir(
    dir,
    "binary",
    @io.MemoryReader(writer => writer.write(bytes)),
  )
  inspect(@fs.can_execute(dir), content="true")
  inspect(@fs.read_file(dir + "/binary").binary() == bytes, content="true")
  inspect(@fs.readdir(dir, include_hidden=true).length(), content="1")
}

///|
async test "object upload accepts empty files and replaces complete objects atomically" {
  let dir = @fs.tmpdir(prefix="msgtier-object-test-")
  defer @fs.rmdir(dir, recursive=true)
  save_object_in_dir(
    dir,
    "object",
    @io.MemoryReader(writer => writer.write(b"old")),
  )
  save_object_in_dir(dir, "object", @io.MemoryReader(_ => ()))
  inspect(@fs.file_size(dir + "/object"), content="0")
  save_object_in_dir(
    dir,
    "object",
    @io.MemoryReader(writer => writer.write(b"new")),
  )
  inspect(@fs.read_file(dir + "/object").text(), content="new")
  inspect(@fs.readdir(dir, include_hidden=true).length(), content="1")
}

///|
async test "concurrent first uploads share directory creation safely" {
  let root = @fs.tmpdir(prefix="msgtier-object-test-")
  defer @fs.rmdir(root, recursive=true)
  let dir = root + "/nested/uploads"
  @async.with_task_group(group => {
    for i in 0..<8 {
      group.spawn_bg(() => {
        let text = "payload-\{i}"
        save_object_in_dir(
          dir,
          "object-\{i}",
          @io.MemoryReader(writer => writer.write(text)),
        )
        assert_eq(@fs.read_file(dir + "/object-\{i}").text(), text)
      })
    }
  })
  inspect(@fs.readdir(dir, include_hidden=true).length(), content="8")
}

///|
async test "cancelled partial upload preserves old object and removes temporary bytes" {
  let dir = @fs.tmpdir(prefix="msgtier-object-test-")
  defer @fs.rmdir(dir, recursive=true)
  @fs.write_file(dir + "/object", "old")
  let (reader, writer) = @io.pipe()
  defer reader.close()
  defer writer.close()
  @async.with_task_group(group => {
    group.spawn_bg(() => writer.write(b"partial upload"))
    let result = @async.with_timeout_opt(100, () => {
      save_object_in_dir(dir, "object", reader)
    })
    inspect(result is None, content="true")
  })
  inspect(@fs.read_file(dir + "/object").text(), content="old")
  inspect(@fs.readdir(dir, include_hidden=true).length(), content="1")
}

///|
async test "failed final rename cleans temporary upload without replacing a directory" {
  let dir = @fs.tmpdir(prefix="msgtier-object-test-")
  defer @fs.rmdir(dir, recursive=true)
  @fs.mkdir(dir + "/object")
  try
    save_object_in_dir(
      dir,
      "object",
      @io.MemoryReader(writer => writer.write(b"data")),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("cannot replace a directory with an object")
  }
  inspect(@fs.readdir(dir, include_hidden=true).length(), content="1")
  inspect(@fs.readdir(dir + "/object").is_empty(), content="true")
}

///|
test "object IDs reject traversal and unpublished upload paths" {
  for
    id in [
      "", ".", "..", "../secret", "/tmp/file", "a/b", "a\\b", ".upload-hidden", "a\u0000b",
    ] {
    assert_false(is_valid_object_id(id))
  }
  inspect(is_valid_object_id("file-123_ABC.txt"), content="true")
}

///|
test "timed out object requests release partial response chunks and ignore late chunks" {
  let id = "object-timeout-regression"
  add_pending_request(id)
  defer remove_pending_request(id)
  inspect(
    store_response_chunk(id, 0, 2, b"first", Some("206"), None) is None,
    content="true",
  )
  inspect(
    app_data_handler_state.pending_response_chunks.contains(id),
    content="true",
  )
  remove_pending_request(id)
  inspect(
    app_data_handler_state.pending_response_chunks.contains(id),
    content="false",
  )
  inspect(
    store_response_chunk(id, 1, 2, b"late", None, None) is None,
    content="true",
  )
  inspect(
    app_data_handler_state.pending_response_chunks.contains(id),
    content="false",
  )
}

///|
test "active object requests assemble reordered chunks and discard invalid indexes" {
  let id = "object-chunks-regression"
  add_pending_request(id)
  defer remove_pending_request(id)
  inspect(
    store_response_chunk(id, -1, 2, b"bad", None, None) is None,
    content="true",
  )
  inspect(
    store_response_chunk(id, 2, 2, b"bad", None, None) is None,
    content="true",
  )
  inspect(
    store_response_chunk(id, 1, 2, b"second", None, None) is None,
    content="true",
  )
  let result = store_response_chunk(id, 0, 2, b"first", Some("206"), None)
  guard result is Some((bytes, status, _)) else {
    fail("expected complete response")
  }
  inspect(bytes == b"firstsecond", content="true")
  inspect(status.unwrap_or(""), content="206")
  inspect(
    app_data_handler_state.pending_response_chunks.contains(id),
    content="false",
  )
}
