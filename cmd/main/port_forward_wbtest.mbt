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
test "normalize port forward connect host" {
  inspect(normalize_port_forward_connect_host("0.0.0.0"), content="127.0.0.1")
  inspect(normalize_port_forward_connect_host(" :: "), content="::1")
  inspect(normalize_port_forward_connect_host("127.0.0.1"), content="127.0.0.1")
}

///|
test "port forward metadata reflects runtime state only" {
  app_state.config = Some(make_port_forward_test_config())
  let rule : PortForwardForwardRule = {
    id: "web",
    protocol: "http",
    peer_id: "node-b",
    listen_host: "127.0.0.1",
    listen_port: 18080,
    enabled: None,
  }
  let rule_key = make_port_forward_forward_rule_key(rule)
  port_mapping_store_state.active_rules = Some([rule])
  port_forward_registry_state.tcp_forward_started[rule_key] = true
  let json = get_port_forward_metadata_json()
  inspect(json.contains("\"direction\":\"forward\""), content="true")
  inspect(json.contains("\"listen_port\":18080"), content="true")
  inspect(json.contains("\"protocol\":\"http\""), content="true")
  inspect(json.contains("\"target_port\""), content="false")
  inspect(json.contains("\"target_host\""), content="false")
  port_forward_registry_state.tcp_forward_started.remove(rule_key)
  port_mapping_store_state.active_rules = None
}
