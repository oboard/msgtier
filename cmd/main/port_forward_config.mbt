///|
struct PortForwardForwardRule {
  id : String
  protocol : String
  peer_id : String
  listen_host : String
  listen_port : Int
  enabled : Bool?
} derive(Debug, ToJson, FromJson)

///|
/// Normalize a raw scheme/protocol string.
///
/// Accepts `tcp`, `udp`, `http` (possibly with a trailing colon or mixed case).
/// Returns None for anything else so callers can reject invalid rules.
fn normalize_port_forward_protocol(raw : String) -> String? {
  let value0 = raw.trim().to_owned().to_lower()
  let value = if value0.has_suffix(":") {
    value0[:value0.length() - 1].to_owned()
  } else {
    value0
  }
  if value == "tcp" || value == "udp" || value == "http" {
    Some(value)
  } else {
    None
  }
}

///|
fn is_port_forward_tcp_protocol(protocol : String) -> Bool {
  protocol == "tcp" || protocol == "http"
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
