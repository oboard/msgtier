///|
test "ProxyMessage roundtrip" {
  let original = ProxyMessage::{
    op: "connect",
    conn_id: "test-conn-123",
    target_addr: Some("127.0.0.1:8080"),
    data: Some(b"\x01\x02\x03"),
  }
  let msgpack = original.to_msgpack()
  let decoded = ProxyMessage::from_msgpack(msgpack)
  match decoded {
    Some(msg) => {
      assert_eq(msg.op, original.op)
      assert_eq(msg.conn_id, original.conn_id)
      assert_eq(msg.target_addr, original.target_addr)
      assert_eq(msg.data, original.data)
    }
    None => fail("Failed to decode ProxyMessage")
  }
}

///|
test "ProxyMessage minimal roundtrip" {
  let original = ProxyMessage::{
    op: "close",
    conn_id: "test-conn-456",
    target_addr: None,
    data: None,
  }
  let msgpack = original.to_msgpack()
  let decoded = ProxyMessage::from_msgpack(msgpack)
  match decoded {
    Some(msg) => {
      assert_eq(msg.op, original.op)
      assert_eq(msg.conn_id, original.conn_id)
      assert_eq(msg.target_addr, original.target_addr)
      assert_eq(msg.data, original.data)
    }
    None => fail("Failed to decode ProxyMessage")
  }
}
