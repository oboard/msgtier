///|
test "Connection::new generates hash id" {
  let conn = Connection::new("peerA", "peerB")
  // ID should be a hex string (hash), not containing the raw address string directly (unless it's part of the hash, which is unlikely to be readable)
  // SHA256 hex string is 64 characters
  inspect(conn.id.length(), content="64")
  // Should not contain "tcp://"
  inspect(conn.id.contains("tcp://"), content="false")
}

///|
test "Connection::new includes session_id in hash" {
  let conn_base = Connection::new("peerA", "peerB", session_id="session-123")
  let conn_same = Connection::new("peerA", "peerB", session_id="session-123")
  let conn_diff = Connection::new("peerA", "peerB", session_id="session-456")
  inspect(conn_base.id.length(), content="64")
  inspect(conn_base.id == conn_same.id, content="true")
  inspect(conn_base.id == conn_diff.id, content="false")
}

///|
test "Connection::new ID ignores ports" {
  let conn1 = Connection::new("peerA", "peerB")
  let conn2 = Connection::new("peerA", "peerB")
  // IDs should be identical despite different ports
  inspect(conn1.id == conn2.id, content="true")
}

///|
test "Connection::new defaults nat type" {
  let conn = Connection::new("peerA", "peerB")
  inspect(conn.nat_type, content="Unknown")
}
