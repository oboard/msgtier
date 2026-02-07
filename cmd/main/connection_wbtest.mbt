///|
test "Connection::new generates hash id" {
  let conn = Connection::new(
    "peerA", "peerB", "tcp://127.0.0.1:8000", "tcp://127.0.0.1:9000", "tcp",
  )
  // ID should be a hex string (hash), not containing the raw address string directly (unless it's part of the hash, which is unlikely to be readable)
  // SHA256 hex string is 64 characters
  inspect(conn.id.length(), content="64")
  // Should not contain "tcp://"
  inspect(conn.id.contains("tcp://"), content="false")
}

///|
test "Connection::new ID ignores ports" {
  let conn1 = Connection::new(
    "peerA", "peerB", "tcp://127.0.0.1:8000", "tcp://127.0.0.1:9000", "tcp",
  )
  let conn2 = Connection::new(
    "peerA", "peerB", "tcp://127.0.0.1:8001", "tcp://127.0.0.1:9002", "tcp",
  )
  // IDs should be identical despite different ports
  inspect(conn1.id == conn2.id, content="true")
}

///|
test "Connection::new analyzes NAT type" {
  let conn_local = Connection::new(
    "peerA", "peerB", "127.0.0.1:8000", "127.0.0.1:9000", "tcp",
  )
  inspect(conn_local.nat_type, content="NoNAT")

  let conn_remote = Connection::new(
    "peerA", "peerB", "192.168.1.10:8000", "8.8.8.8:9000", "tcp",
  )
  inspect(conn_remote.nat_type, content="Unknown")
}
