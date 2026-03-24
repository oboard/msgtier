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
  let value0 = raw.trim().to_string().to_lower()
  let value = if value0.has_suffix(":") {
    value0[:value0.length() - 1].to_string()
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
  guard @url.Url::parse(raw) is Some(url) else { return None }
  guard normalize_port_forward_protocol(url.protocol()) is Some(protocol) else {
    return None
  }
  guard parse_pf_port(url.get_port()) is Some(port) else { return None }
  guard url.hostname() != "" else { return None }
  Some({
    id,
    protocol,
    target_host: url.hostname(),
    target_port: port,
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
  let key = id.trim().to_string()
  let key_parts = key.split(":").to_array()
  if key_parts.length() != 2 {
    return None
  }
  let peer_id = key_parts[0].trim().to_string()
  let rule_id = key_parts[1].trim().to_string()
  if peer_id == "" || rule_id == "" {
    return None
  }
  let url = @url.Url::parse(raw)
  guard url is Some(url) else { return None }
  let port = parse_pf_port(url.get_port())
  guard url.hostname() != "" && port is Some(_) else { return None }
  guard normalize_port_forward_protocol(url.protocol()) is Some(protocol) else {
    return None
  }
  Some({
    id: rule_id,
    protocol,
    peer_id,
    listen_host: url.hostname(),
    listen_port: port.unwrap_or(0),
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
  let ids = config.exposes.unwrap_or({}).keys().to_array()
  ids.sort_by(fn(a, b) { if a < b { -1 } else if a > b { 1 } else { 0 } })
  for id in ids {
    let spec = config.exposes.unwrap_or({}).get(id).unwrap_or("")
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
  let ids = config.forwards.unwrap_or({}).keys().to_array()
  ids.sort_by(fn(a, b) { if a < b { -1 } else if a > b { 1 } else { 0 } })
  for id in ids {
    let spec = config.forwards.unwrap_or({}).get(id).unwrap_or("")
    let key_id = id.trim().to_string()
    if key_id == "" {
      continue
    }
    let raw = spec.trim().to_string()
    if raw == "" {
      continue
    }
    match parse_port_forward_forward_spec(key_id, raw) {
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
