///|
/// Runtime rule describing "listen locally on `listen_host:listen_port` and
/// forward every accepted connection to `remote_host:remote_port` on `peer_id`
/// over the p2p link". `remote_host` / `remote_port` travel to the expose side
/// in every `port_forward_open` message so the expose side knows what socket
/// to connect to on its end (see `handle_port_forward_open_message`).
struct PortForwardForwardRule {
  id : String
  protocol : String
  peer_id : String
  listen_host : String
  listen_port : Int
  remote_host : String
  remote_port : Int
  enabled : Bool?
} derive(Debug, ToJson, FromJson)

///|
/// Normalize a raw protocol string.
///
/// Trims whitespace, strips a trailing colon (so `"http:"` and `"http"` both
/// map to `http`), and lowercases. Returns `None` only when the input is
/// empty after trimming — any other non-empty label is accepted verbatim.
///
/// We accept arbitrary labels ("https", "ws", "grpc", "mysql", "custom-proto",
/// …) so any protocol built on top of TCP or UDP works. The transport that
/// actually gets used (tcp socket vs udp socket) is decided by
/// [port_forward_transport]; the label itself is kept only for display and
/// routing bookkeeping.
fn normalize_port_forward_protocol(raw : String) -> String? {
  let value0 = raw.trim().to_owned().to_lower()
  let value = if value0.has_suffix(":") {
    value0[:value0.length() - 1].to_owned()
  } else {
    value0
  }
  if value == "" {
    None
  } else {
    Some(value)
  }
}

///|
/// Map any application-layer protocol label to its underlying transport.
///
/// - `udp` → `udp` (the only currently-known UDP-based label).
/// - Everything else → `tcp`. This is deliberately the default: HTTP, HTTPS,
///   WS, WSS, gRPC, MySQL, Redis, PostgreSQL, MongoDB, SSH, SMTP, IMAP, POP3,
///   FTP, Telnet, and any user-supplied label all ride on TCP. Making TCP the
///   default lets a mapping created with `remote_protocol="mysql"` (or any
///   other custom label) work without teaching this table about it.
///
/// This function is what expose-side authorization
/// ([handle_port_forward_open_message]) uses when it looks up the target port
/// in the scanner's broadcast set — the scanner only ever labels sockets as
/// `tcp` or `udp`, never as their application protocol.
fn port_forward_transport(protocol : String) -> String {
  if protocol == "udp" {
    "udp"
  } else {
    "tcp"
  }
}

///|
fn is_port_forward_tcp_protocol(protocol : String) -> Bool {
  port_forward_transport(protocol) == "tcp"
}

///|
fn normalize_port_forward_connect_host(host : String) -> String {
  let value = host.trim().to_owned()
  if value == "" || value == "0.0.0.0" {
    "127.0.0.1"
  } else if value == "::" || value == "[::]" {
    "::1"
  } else {
    value
  }
}

///|
fn is_port_forward_rule_enabled(enabled : Bool?) -> Bool {
  enabled.unwrap_or(true)
}

///|
fn is_valid_port_forward_port(port : Int) -> Bool {
  port > 0 && port <= 65535
}

///|
fn make_port_forward_socket_addr(host : String, port : Int) -> String {
  if host.contains(":") && !host.has_prefix("[") {
    "[" + host + "]:" + port.to_string()
  } else {
    host + ":" + port.to_string()
  }
}

///|
fn make_port_forward_forward_rule_key(rule : PortForwardForwardRule) -> String {
  rule.protocol +
  "|" +
  rule.id +
  "|" +
  rule.peer_id +
  "|" +
  rule.listen_host +
  "|" +
  rule.listen_port.to_string()
}
