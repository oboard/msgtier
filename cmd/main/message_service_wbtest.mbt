///|
test "sync message includes local script metadata" {
  app_state.config = Some({
    id: "node-a",
    secret: "secret",
    peers: [],
    listeners: ["tcp://0.0.0.0:10000"],
    scripts: Some({ "ping": "echo ping", "build": "echo build" }),
    web_api: None,
    metadata: Some({ "role": "worker" }),
    openclaw: None,
    openclaw_plugin_version: None,
    openclaw_token: None,
    log: None,
    port: None,
    relay_network_whitelist: None,
    relay_all_peer_rpc: None,
    foreign_relay_bps_limit: None,
    upload_dir: None,
    disable_encryption: None,
  })
  global_state.connection_manager = ConnectionManager::new()

  let conn = Connection::{
    ..Connection::new("node-a", "node-b"),
    version: "test-version",
  }
  global_state.connection_manager = global_state.connection_manager.add_connection(
    conn,
  )

  let msg = create_sync_message("node-a", "tcp://127.0.0.1:10000")
  match msg.body {
    Array(entries) => {
      assert_eq(entries.length(), 1)
      let parsed = Connection::from_msgpack(entries[0]).unwrap()
      let metadata = parsed.metadata.unwrap()
      inspect(metadata.get("role").unwrap(), content="worker")
      inspect(metadata.get("scripts").unwrap().contains("ping"), content="true")
      inspect(
        metadata.get("scripts").unwrap().contains("build"),
        content="true",
      )
      inspect(metadata.get("channels").unwrap().has_prefix("["), content="true")
      inspect(metadata.get("openclaw").unwrap().has_prefix("["), content="true")
    }
    _ => fail("sync message body should be an array")
  }
}
