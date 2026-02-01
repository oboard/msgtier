///|
test "message roundtrip encoding/decoding" {
  // Create a test message with minimal fields
  let original : Message = Message::new(
    id="test-msg-1",
    kind="hello",
    from="node-a",
    addr="127.0.0.1:8000",
    version=Some("1.0"),
    relay=1,
    encrypted=false,
  )

  // Encode to msgpack
  let encoded = original.to_msgpack()

  // Decode back
  let decoded : Message = @msgpack.decode(encoded) |> Message::from_msgpack()

  // Verify fields match
  assert_eq(decoded.id, original.id)
  assert_eq(decoded.kind, original.kind)
  assert_eq(decoded.from, original.from)
  assert_eq(decoded.addr, original.addr)
  assert_eq(decoded.version, original.version)
  assert_eq(decoded.relay, original.relay)
  assert_eq(decoded.encrypted, original.encrypted)
}

///|
test "message with optional fields subset 1" {
  // Test a subset of optional fields
  let original : Message = Message::new(
    id="test-msg-2",
    kind="data",
    from="node-a",
    addr="127.0.0.1:8000",
    version=Some("1.0"),
    relay=2,
    encrypted=true,
  )

  // Encode to msgpack
  let encoded = original.to_msgpack()

  // Decode back
  let decoded : Message = @msgpack.decode(encoded) |> Message::from_msgpack()

  // Verify fields match
  assert_eq(decoded.id, original.id)
  assert_eq(decoded.kind, original.kind)
  assert_eq(decoded.from, original.from)
  assert_eq(decoded.addr, original.addr)
  assert_eq(decoded.version, original.version)
  assert_eq(decoded.relay, original.relay)
  assert_eq(decoded.encrypted, original.encrypted)
}

///|
test "message with peers" {
  // Test peers separately since that's where the error likely is
  let peers_list : Array[NetworkAddress] = [
    NetworkAddress::{ address: "127.0.0.1:8001" },
    NetworkAddress::{ address: "127.0.0.1:8002" },
  ]
  let original : Message = Message::new(
    id="test-msg-3",
    kind="data",
    from="node-a",
    addr="127.0.0.1:8000",
    peers=Some(peers_list),
  )

  // Encode to msgpack
  let encoded = original.to_msgpack()

  // Decode back
  let decoded : Message = @msgpack.decode(encoded) |> Message::from_msgpack()

  // Check peers
  match decoded.peers {
    Some(peers) => {
      assert_eq(peers.length(), 2)
      assert_eq(peers[0].address, "127.0.0.1:8001")
      assert_eq(peers[1].address, "127.0.0.1:8002")
    }
    None => fail("Expected peers but got None")
  }
}

///|
test "message with short array (pre-optional fields)" {
  // Simulate a message encoded with only the required fields (6 elements)
  let short_array : Array[@msgpack.Value] = [
    @msgpack.string("msg-id"),
    @msgpack.string("hello"),
    @msgpack.string("node-a"),
    @msgpack.string("127.0.0.1:8000"),
    @msgpack.int(1),
    @msgpack.bool(false),
  ]
  let msgpack_value = @msgpack.array(short_array)
  let decoded : Message = Message::from_msgpack(msgpack_value)

  // Verify required fields are decoded correctly
  assert_eq(decoded.id, "msg-id")
  assert_eq(decoded.kind, "hello")
  assert_eq(decoded.from, "node-a")
  assert_eq(decoded.addr, "127.0.0.1:8000")
  assert_eq(decoded.relay, 1)
  assert_eq(decoded.encrypted, false)

  // Verify optional fields are None
  assert_eq(decoded.version, None)
  assert_eq(decoded.public_key, None)
  assert_eq(decoded.secret_hash, None)
  assert_eq(decoded.payload, None)
  assert_eq(decoded.target, None)
  assert_eq(decoded.data, None)
  assert_eq(decoded.peers, None)
}
