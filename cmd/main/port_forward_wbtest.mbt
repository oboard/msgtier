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
      "node-b:dns": "udp://127.0.0.1:1053",
      "node-b:broken": "icmp://127.0.0.1:1",
    }),
    exposes: Some({
      "db": "tcp://localhost:5432",
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
test "parse port forward object config" {
  app_state.config = Some(make_port_forward_test_config())
  let exposes = get_port_forward_expose_rules()
  let forwards = get_port_forward_forward_rules()
  inspect(exposes.length(), content="2")
  inspect(forwards.length(), content="2")
  inspect(exposes[0].id, content="db")
  inspect(exposes[0].target_port.to_string(), content="5432")
  inspect(forwards[0].peer_id, content="node-b")
  inspect(forwards[1].protocol, content="udp")
}

///|
test "find matching expose rule by key and protocol" {
  app_state.config = Some(make_port_forward_test_config())
  inspect(find_port_forward_expose_rule("db", "tcp") is Some(_), content="true")
  inspect(find_port_forward_expose_rule("db", "udp") is None, content="true")
  inspect(
    find_port_forward_expose_rule("missing", "tcp") is None,
    content="true",
  )
}

///|
test "port forward metadata exports public fields only" {
  app_state.config = Some(make_port_forward_test_config())
  let rule_key = make_port_forward_forward_rule_key(
    get_port_forward_forward_rules()[0],
  )
  port_forward_registry_state.tcp_forward_started[rule_key] = true
  let json = get_port_forward_metadata_json()
  inspect(json.contains("\"direction\":\"expose\""), content="true")
  inspect(json.contains("\"direction\":\"forward\""), content="true")
  inspect(json.contains("\"listen_port\":15432"), content="true")
  inspect(json.contains("\"target_port\""), content="false")
  inspect(json.contains("\"target_host\""), content="false")
  inspect(json.contains("\"peer_ids\""), content="false")
  port_forward_registry_state.tcp_forward_started.remove(rule_key)
}
