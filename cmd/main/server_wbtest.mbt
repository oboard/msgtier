///|
test "learn_route_from_relayed_message records next hop from sender addr" {
  app_state.config = Some({
    id: "node-b",
    secret: "secret",
    peers: [],
    listeners: [],
    scripts: None,
    web_api: None,
    metadata: None,
    openclaw: None,
    openclaw_plugin_version: None,
    openclaw_token: None,
    forwards: None,
    exposes: None,
    log: Some(Debug),
    relay_network_whitelist: None,
    relay_all_peer_rpc: None,
    foreign_relay_bps_limit: None,
    upload_dir: None,
    disable_encryption: Some(true),
    hot_reload: None,
  })
  global_state.peer_manager = PeerManager::new()
  global_state.peer_manager = global_state.peer_manager.add_peer(
    PeerNode::new(id="node-c", version="", addresses=["tcp://relay-hop:2000"], metadata={}),
  )
  learn_route_from_relayed_message(
    "node-b", "node-a", "tcp://relay-hop:2000", 2,
  )
  inspect(
    get_global_peer_manager()
    .get_route("node-a")
    .map(r => r.next_hop)
    .unwrap_or(""),
    content="node-c",
  )
  inspect(
    get_global_peer_manager()
    .get_route("node-a")
    .map(r => r.hops.to_string())
    .unwrap_or(""),
    content="2",
  )
}
