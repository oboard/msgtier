///|
struct PortForwardExposeRule {
  id : String
  protocol : String
  allow_from_peers : Array[String]
  allow_from_peer : String?
  target_host : String
  target_port : Int
  target : String?
  enabled : Bool?
} derive(Show, ToJson, FromJson)

///|
struct PortForwardForwardRule {
  id : String
  protocol : String
  peer_id : String
  listen_host : String
  listen_port : Int
  listen : String?
  enabled : Bool?
} derive(Show, ToJson, FromJson)

///|
fn normalize_port_forward_protocol(raw : String) -> String? {
  let value = raw.trim().to_string().to_lower()
  if value == "tcp" || value == "udp" {
    Some(value)
  } else {
    None
  }
}

///|
fn normalize_port_forward_protocol_with_default(raw : String) -> String? {
  let value = raw.trim().to_string()
  if value == "" {
    Some("tcp")
  } else {
    normalize_port_forward_protocol(value)
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
fn parse_port_forward_int(raw : String) -> Int? {
  let value = raw.trim().to_string()
  if value == "" {
    return None
  }
  let mut result = 0
  for c in value {
    if c < '0' || c > '9' {
      return None
    }
    result = result * 10 + (c.to_int() - '0'.to_int())
  }
  if is_valid_port_forward_port(result) {
    Some(result)
  } else {
    None
  }
}

///|
fn parse_port_forward_host_port(
  raw : String?,
  default_host : String,
) -> (String, Int)? {
  let spec = raw.unwrap_or("").trim().to_string()
  if spec == "" {
    return None
  }
  if parse_port_forward_int(spec) is Some(port) {
    return Some((default_host, port))
  }
  let mut last_colon = -1
  let mut i = 0
  for c in spec {
    if c == ':' {
      last_colon = i
    }
    i = i + 1
  }
  if last_colon <= 0 || last_colon >= spec.length() - 1 {
    return None
  }
  let host = spec[0:last_colon].trim().to_string()
  let port_str = spec[last_colon + 1:].trim().to_string()
  if host == "" {
    return None
  }
  match parse_port_forward_int(port_str) {
    Some(port) => Some((host, port))
    None => None
  }
}

///|
fn sanitize_port_forward_expose_rules(
  rules : Array[PortForwardExposeRule]?,
) -> Array[PortForwardExposeRule] {
  let out : Array[PortForwardExposeRule] = []
  let seen : Map[String, Bool] = {}
  for rule in rules.unwrap_or([]) {
    guard normalize_port_forward_protocol_with_default(rule.protocol)
      is Some(protocol) else {
      continue
    }
    let id = rule.id.trim().to_string()
    let allow_from_peer = rule.allow_from_peer.unwrap_or("").trim().to_string()
    let allow_from_peers = if !rule.allow_from_peers.is_empty() {
      rule.allow_from_peers
      .map(peer => peer.trim().to_string())
      .filter(peer => peer != "")
    } else if allow_from_peer != "" {
      [allow_from_peer]
    } else {
      []
    }
    let target_host = rule.target_host.trim().to_string()
    let target_port = rule.target_port
    let (resolved_target_host, resolved_target_port) = match
      parse_port_forward_host_port(rule.target, "127.0.0.1") {
      Some((host, port)) =>
        if target_host == "" || !is_valid_port_forward_port(target_port) {
          (host, port)
        } else {
          (target_host, target_port)
        }
      None => (target_host, target_port)
    }
    if id == "" ||
      resolved_target_host == "" ||
      allow_from_peers.is_empty() ||
      !is_valid_port_forward_port(resolved_target_port) {
      continue
    }
    let key = protocol + "|" + id
    if seen.contains(key) {
      continue
    }
    seen[key] = true
    out.push({
      ..rule,
      id,
      protocol,
      allow_from_peers,
      target_host: resolved_target_host,
      target_port: resolved_target_port,
    })
  }
  out
}

///|
fn sanitize_port_forward_forward_rules(
  rules : Array[PortForwardForwardRule]?,
) -> Array[PortForwardForwardRule] {
  let out : Array[PortForwardForwardRule] = []
  let seen : Map[String, Bool] = {}
  for rule in rules.unwrap_or([]) {
    guard normalize_port_forward_protocol_with_default(rule.protocol)
      is Some(protocol) else {
      continue
    }
    let id = rule.id.trim().to_string()
    let peer_id = rule.peer_id.trim().to_string()
    let listen_host = rule.listen_host.trim().to_string()
    let listen_port = rule.listen_port
    let (resolved_listen_host, resolved_listen_port) = match
      parse_port_forward_host_port(rule.listen, "127.0.0.1") {
      Some((host, port)) =>
        if listen_host == "" || !is_valid_port_forward_port(listen_port) {
          (host, port)
        } else {
          (listen_host, listen_port)
        }
      None => (listen_host, listen_port)
    }
    if id == "" ||
      peer_id == "" ||
      resolved_listen_host == "" ||
      !is_valid_port_forward_port(resolved_listen_port) {
      continue
    }
    let key = protocol +
      "|" +
      id +
      "|" +
      peer_id +
      "|" +
      resolved_listen_host +
      "|" +
      resolved_listen_port.to_string()
    if seen.contains(key) {
      continue
    }
    seen[key] = true
    out.push({
      ..rule,
      id,
      protocol,
      peer_id,
      listen_host: resolved_listen_host,
      listen_port: resolved_listen_port,
    })
  }
  out
}

///|
fn get_port_forward_expose_rules() -> Array[PortForwardExposeRule] {
  sanitize_port_forward_expose_rules(get_config().port_forward_exposes)
}

///|
fn get_port_forward_forward_rules() -> Array[PortForwardForwardRule] {
  sanitize_port_forward_forward_rules(get_config().port_forward_forwards)
}

///|
fn find_port_forward_expose_rule(
  rule_id : String,
  protocol : String,
  requester_peer_id : String,
) -> PortForwardExposeRule? {
  let normalized_protocol = normalize_port_forward_protocol(protocol)
  for rule in get_port_forward_expose_rules() {
    if !is_port_forward_rule_enabled(rule.enabled) {
      continue
    }
    if rule.id == rule_id &&
      normalized_protocol == Some(rule.protocol) &&
      rule.allow_from_peers.contains(requester_peer_id) {
      return Some(rule)
    }
  }
  None
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
