///|
fn make_config_hot_reload_test_config() -> Config {
  {
    id: "node-a",
    secret: "network-secret",
    peers: ["tcp://127.0.0.1:9001"],
    listeners: ["tcp://127.0.0.1:9000"],
    scripts: Some({ "ping": "echo ping" }),
    web_api: Some("127.0.0.1:19000"),
    metadata: Some({ "role": "worker" }),
    openclaw: None,
    openclaw_plugin_version: None,
    openclaw_token: None,
    forwards: Some({ "node-b:ssh": "tcp://127.0.0.1:10022" }),
    exposes: Some({ "ssh": "tcp://127.0.0.1:22" }),
    log: None,
    relay_network_whitelist: None,
    relay_all_peer_rpc: Some(true),
    foreign_relay_bps_limit: None,
    upload_dir: None,
    disable_encryption: None,
    hot_reload: Some({ enable: Some(true), secret: Some("reload-secret") }),
  }
}

///|
test "config response json exposes static and hot layers" {
  set_config(make_config_hot_reload_test_config())
  let json = get_config_response_json().stringify()
  inspect(json.contains("\"static_config\""), content="true")
  inspect(json.contains("\"hot_config\""), content="true")
  inspect(json.contains("\"hot_reload\""), content="true")
}

///|
test "apply hot reload request updates hot fields" {
  set_config(make_config_hot_reload_test_config())
  let result = apply_hot_reload_request(
    "{\"secret\":\"reload-secret\",\"config\":{\"scripts\":{\"build\":\"echo build\"},\"forwards\":{},\"exposes\":{},\"hot_reload\":{\"enable\":true,\"secret\":\"next-secret\"}}}",
  )
  inspect(result is Ok(_), content="true")
  let config = get_config()
  inspect(config.scripts.unwrap().contains("build"), content="true")
  inspect(config.forwards.unwrap().is_empty(), content="true")
  inspect(config.exposes.unwrap().is_empty(), content="true")
  inspect(config.hot_reload.unwrap().secret.unwrap(), content="next-secret")
}

///|
test "apply hot reload request rejects static fields" {
  set_config(make_config_hot_reload_test_config())
  let result = apply_hot_reload_request(
    "{\"secret\":\"reload-secret\",\"config\":{\"listeners\":[\"tcp://127.0.0.1:9999\"]}}",
  )
  inspect(result is Err(_), content="true")
}

///|
test "apply hot reload request enforces secret" {
  set_config(make_config_hot_reload_test_config())
  let result = apply_hot_reload_request(
    "{\"secret\":\"wrong-secret\",\"config\":{\"scripts\":{\"build\":\"echo build\"}}}",
  )
  inspect(result is Err(_), content="true")
}
