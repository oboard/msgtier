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
    port_forward_exposes: Some([
      {
        id: "db",
        protocol: "tcp",
        allow_from_peers: ["node-b"],
        allow_from_peer: None,
        target_host: "127.0.0.1",
        target_port: 5432,
        target: None,
        enabled: Some(true),
      },
      {
        id: "bad",
        protocol: "icmp",
        allow_from_peers: ["node-b"],
        allow_from_peer: None,
        target_host: "127.0.0.1",
        target_port: 0,
        target: None,
        enabled: Some(true),
      },
    ]),
    port_forward_forwards: Some([
      {
        id: "db",
        protocol: "tcp",
        peer_id: "node-b",
        listen_host: "127.0.0.1",
        listen_port: 15432,
        listen: None,
        enabled: Some(true),
      },
      {
        id: "dns",
        protocol: "udp",
        peer_id: "node-b",
        listen_host: "127.0.0.1",
        listen_port: 1053,
        listen: None,
        enabled: Some(false),
      },
    ]),
    log: None,
    port: None,
    relay_network_whitelist: None,
    relay_all_peer_rpc: None,
    foreign_relay_bps_limit: None,
    upload_dir: None,
    disable_encryption: None,
  }
}

///|
test "sanitize port forward rules filters invalid entries" {
  let config = make_port_forward_test_config()
  app_state.config = Some(config)
  let exposes = get_port_forward_expose_rules()
  let forwards = get_port_forward_forward_rules()
  inspect(exposes.length(), content="1")
  inspect(forwards.length(), content="2")
  inspect(exposes[0].protocol, content="tcp")
  inspect(forwards[0].id, content="db")
}

///|
test "find matching expose rule enforces allowlist" {
  app_state.config = Some(make_port_forward_test_config())
  inspect(
    find_port_forward_expose_rule("db", "tcp", "node-b") is Some(_),
    content="true",
  )
  inspect(
    find_port_forward_expose_rule("db", "tcp", "node-c") is None,
    content="true",
  )
}

///|
test "port forward shorthand config is expanded" {
  app_state.config = Some({
    ..make_port_forward_test_config(),
    port_forward_exposes: Some([
      {
        id: "redis",
        protocol: "",
        allow_from_peers: [],
        allow_from_peer: Some("node-b"),
        target_host: "",
        target_port: 0,
        target: Some("6380"),
        enabled: None,
      },
    ]),
    port_forward_forwards: Some([
      {
        id: "redis",
        protocol: "",
        peer_id: "node-b",
        listen_host: "",
        listen_port: 0,
        listen: Some("16380"),
        enabled: None,
      },
    ]),
  })
  let expose = get_port_forward_expose_rules()[0]
  let forward = get_port_forward_forward_rules()[0]
  inspect(expose.protocol, content="tcp")
  inspect(expose.allow_from_peers.join(","), content="node-b")
  inspect(expose.target_host, content="127.0.0.1")
  inspect(expose.target_port.to_string(), content="6380")
  inspect(forward.protocol, content="tcp")
  inspect(forward.listen_host, content="127.0.0.1")
  inspect(forward.listen_port.to_string(), content="16380")
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
  port_forward_registry_state.tcp_forward_started.remove(rule_key)
}
