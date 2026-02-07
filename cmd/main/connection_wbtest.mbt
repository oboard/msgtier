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
