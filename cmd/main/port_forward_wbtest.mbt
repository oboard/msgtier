///|
fn make_port_forward_test_config() -> Config {
  {
    id: "node-a",
    secret: "secret",
    peers: [],
    listeners: [],
    scripts: None,
    web_api: None,
    metadata: None,
    openclaw: None,
    openclaw_plugin_version: None,
    openclaw_token: None,
    forwards: Some({
      "node-b:db": "tcp://127.0.0.1:15432",
      "node-b:web": "http://127.0.0.1:18080",
      "node-b:dns": "udp://127.0.0.1:1053",
      "node-b:broken": "icmp://127.0.0.1:1",
    }),
    exposes: Some({
      "db": "tcp://localhost:5432",
      "web": "http://127.0.0.1:8080",
      "dns": "udp://127.0.0.1:53",
      "bad": "tcp://localhost:0",
    }),
    log: None,
    relay_network_whitelist: None,
    relay_all_peer_rpc: None,
    foreign_relay_bps_limit: None,
    upload_dir: None,
    disable_encryption: None,
    hot_reload: None,
  }
}

///|
fn find_test_expose_rule(
  rules : Array[PortForwardExposeRule],
  id : String,
) -> PortForwardExposeRule? {
  for rule in rules {
    if rule.id == id {
      return Some(rule)
    }
  }
  None
}

///|
fn find_test_forward_rule(
  rules : Array[PortForwardForwardRule],
  id : String,
) -> PortForwardForwardRule? {
  for rule in rules {
    if rule.id == id {
      return Some(rule)
    }
  }
  None
}

///|
test "parse port forward object config" {
  app_state.config = Some(make_port_forward_test_config())
  let exposes = get_port_forward_expose_rules()
  let forwards = get_port_forward_forward_rules()
  inspect(exposes.length(), content="3")
  inspect(forwards.length(), content="3")
  inspect(find_test_expose_rule(exposes, "db") is Some(_), content="true")
  inspect(
    find_test_expose_rule(exposes, "db").unwrap().target_port.to_string(),
    content="5432",
  )
  inspect(
    find_test_forward_rule(forwards, "db").unwrap().peer_id,
    content="node-b",
  )
  inspect(
    find_test_forward_rule(forwards, "dns").unwrap().protocol,
    content="udp",
  )
  inspect(
    find_test_forward_rule(forwards, "web").unwrap().protocol,
    content="http",
  )
}

///|
test "find matching expose rule by key and protocol" {
  app_state.config = Some(make_port_forward_test_config())
  inspect(find_port_forward_expose_rule("db", "tcp") is Some(_), content="true")
  inspect(
    find_port_forward_expose_rule("web", "http") is Some(_),
    content="true",
  )
  inspect(find_port_forward_expose_rule("db", "udp") is None, content="true")
  inspect(
    find_port_forward_expose_rule("missing", "tcp") is None,
    content="true",
  )
}

///|
test "normalize port forward connect host" {
  inspect(normalize_port_forward_connect_host("0.0.0.0"), content="127.0.0.1")
  inspect(normalize_port_forward_connect_host(" :: "), content="::1")
  inspect(normalize_port_forward_connect_host("127.0.0.1"), content="127.0.0.1")
}

///|
test "port forward metadata exports public fields only" {
  app_state.config = Some(make_port_forward_test_config())
  let rule_key = make_port_forward_forward_rule_key({
    id: "web",
    protocol: "http",
    peer_id: "node-b",
    listen_host: "127.0.0.1",
    listen_port: 18080,
    enabled: None,
  })
  port_forward_registry_state.tcp_forward_started[rule_key] = true
  let json = get_port_forward_metadata_json()
  inspect(json.contains("\"direction\":\"expose\""), content="true")
  inspect(json.contains("\"direction\":\"forward\""), content="true")
  inspect(json.contains("\"listen_port\":18080"), content="true")
  inspect(json.contains("\"protocol\":\"http\""), content="true")
  inspect(json.contains("\"target_port\""), content="false")
  inspect(json.contains("\"target_host\""), content="false")
  inspect(json.contains("\"peer_ids\""), content="false")
  port_forward_registry_state.tcp_forward_started.remove(rule_key)
}
