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
test "Connection::new includes session_id in hash" {
  let conn_base = Connection::new(
    "peerA", "peerB", "tcp://127.0.0.1:8000", "tcp://127.0.0.1:9000", "tcp",
  )
  let conn_session = Connection::new(
    "peerA",
    "peerB",
    "tcp://127.0.0.1:8000",
    "tcp://127.0.0.1:9000",
    "tcp",
    session_id="session-123",
  )
  inspect(conn_session.id.length(), content="64")
  inspect(conn_session.id == conn_base.id, content="false")
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
  // Loopback to Loopback -> NoNAT
  let conn_local = Connection::new(
    "peerA", "peerB", "127.0.0.1:8000", "127.0.0.1:9000", "tcp",
  )
  inspect(conn_local.nat_type, content="NoNAT")

  // Private to Public -> PortRestricted
  let conn_remote = Connection::new(
    "peerA", "peerB", "192.168.1.10:8000", "8.8.8.8:9000", "tcp",
  )
  inspect(conn_remote.nat_type, content="PortRestricted")

  // Public to Public -> NoNAT
  let conn_public = Connection::new(
    "peerA", "peerB", "1.1.1.1:8000", "8.8.8.8:9000", "tcp",
  )
  inspect(conn_public.nat_type, content="NoNAT")

  // Private to Private (Same Subnet) -> NoNAT
  let conn_lan = Connection::new(
    "peerA", "peerB", "192.168.1.10:8000", "192.168.1.20:9000", "tcp",
  )
  inspect(conn_lan.nat_type, content="NoNAT")

  // Private to Private (Diff Subnet) -> Symmetric
  let conn_diff_lan = Connection::new(
    "peerA", "peerB", "192.168.1.10:8000", "192.168.2.20:9000", "tcp",
  )
  inspect(conn_diff_lan.nat_type, content="Symmetric")
}
