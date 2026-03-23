///|
struct PortForwardExposeRule {
  id : String
  protocol : String
  target_host : String
  target_port : Int
  enabled : Bool?
} derive(Show, ToJson, FromJson)

///|
struct PortForwardForwardRule {
  id : String
  protocol : String
  peer_id : String
  listen_host : String
  listen_port : Int
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
fn is_port_forward_rule_enabled(enabled : Bool?) -> Bool {
  enabled.unwrap_or(true)
}

///|
fn is_valid_port_forward_port(port : Int) -> Bool {
  port > 0 && port <= 65535
}

///|
fn parse_port_forward_expose_spec(
  id : String,
  spec : String,
) -> PortForwardExposeRule? {
  let raw = spec.trim().to_string()
  if raw == "" {
    return None
  }
  let addr = Address::parse(raw) catch { _ => return None }
  let protocol = addr.protocol.to_string()
  if protocol != "tcp" && protocol != "udp" {
    return None
  }
  if !is_valid_port_forward_port(addr.port.to_int()) {
    return None
  }
  Some({
    id,
    protocol,
    target_host: addr.host,
    target_port: addr.port.to_int(),
    enabled: None,
  })
}

///|
fn parse_port_forward_forward_spec(
  id : String,
  spec : String,
) -> PortForwardForwardRule? {
  let raw = spec.trim().to_string()
  if raw == "" {
    return None
  }
  let url = @url.Url::parse(raw)
  guard url is Some(url) else { return None }
  let peer_id = url.get_username().trim().to_string()
  let port = parse_pf_port(url.get_port())
  guard peer_id != "" else { return None }
  guard url.hostname() != "" && port is Some(_) else { return None }
  let addr = Address::parse(
    url.protocol() +
    "//" +
    make_port_forward_socket_addr(url.hostname(), port.unwrap_or(0)),
  ) catch {
    _ => return None
  }
  guard normalize_port_forward_protocol(addr.protocol.to_string())
    is Some(normalized_protocol) else {
    return None
  }
  if !is_valid_port_forward_port(addr.port.to_int()) {
    return None
  }
  Some({
    id,
    protocol: normalized_protocol,
    peer_id,
    listen_host: addr.host,
    listen_port: addr.port.to_int(),
    enabled: None,
  })
}

///|
fn parse_pf_port(port_str : String) -> Int? {
  let value = port_str.trim().to_string()
  guard value != "" else { return None }
  let parsed = @strconv.parse_int(value) catch { _ => return None }
  if is_valid_port_forward_port(parsed) {
    Some(parsed)
  } else {
    None
  }
}

///|
fn get_port_forward_expose_rules() -> Array[PortForwardExposeRule] {
  let config = get_config()
  let out : Array[PortForwardExposeRule] = []
  let seen : Map[String, Bool] = {}
  for id, spec in config.exposes.unwrap_or({}) {
    let key_id = id.trim().to_string()
    if key_id == "" {
      continue
    }
    match parse_port_forward_expose_spec(key_id, spec) {
      Some(rule) => {
        let key = rule.protocol + "|" + rule.id
        if !seen.contains(key) {
          seen[key] = true
          out.push(rule)
        }
      }
      None => ()
    }
  }
  out
}

///|
fn get_port_forward_forward_rules() -> Array[PortForwardForwardRule] {
  let config = get_config()
  let out : Array[PortForwardForwardRule] = []
  let seen : Map[String, Bool] = {}
  for id, spec in config.forwards.unwrap_or({}) {
    let key_id = id.trim().to_string()
    if key_id == "" {
      continue
    }
    match parse_port_forward_forward_spec(key_id, spec) {
      Some(rule) => {
        let key = make_port_forward_forward_rule_key(rule)
        if !seen.contains(key) {
          seen[key] = true
          out.push(rule)
        }
      }
      None => ()
    }
  }
  out
}

///|
fn find_port_forward_expose_rule(
  rule_id : String,
  protocol : String,
) -> PortForwardExposeRule? {
  let normalized_protocol = normalize_port_forward_protocol(protocol)
  for rule in get_port_forward_expose_rules() {
    if !is_port_forward_rule_enabled(rule.enabled) {
      continue
    }
    if rule.id == rule_id && normalized_protocol == Some(rule.protocol) {
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
