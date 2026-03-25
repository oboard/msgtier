///|
struct MockRouteTransport {
  sent : Ref[Array[String]]
}

///|
impl Transport for MockRouteTransport with send(self, target, _data) {
  self.sent.val.push(target)
  target == "tcp://relay-hop:2000"
}

///|
impl Transport for MockRouteTransport with listen(
  _self,
  _root,
  _handler,
  _on_disconnect,
) {
  ()
}

///|
impl Transport for MockRouteTransport with local_addr(_self) {
  "127.0.0.1:19000"
}

///|
impl Transport for MockRouteTransport with protocol(_self) {
  "tcp"
}

///|
impl Transport for MockRouteTransport with protocol_type(_self) {
  Tcp
}

///|
impl Transport for MockRouteTransport with local_address(_self) {
  Address::parse("tcp://127.0.0.1:19000") catch {
    _ => abort("invalid mock local address")
  }
}

///|
fn reset_route_test_state() -> Unit {
  global_state.transports.clear()
  global_state.known_peers.clear()
  global_state.peer_manager = PeerManager::new()
  global_state.connection_manager = ConnectionManager::new()
}

///|
async test "send_message_now_with_route falls back to relay route" {
  app_state.config = Some({
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
  reset_route_test_state()

  let direct_addr = "tcp://direct-target:1000"
  let relay_addr = "tcp://relay-hop:2000"
  let now = @env.now()

  let direct_conn = Connection::new("node-a", "node-b").update_address_pong(
    direct_addr, now,
  )
  let relay_conn = Connection::new("node-a", "node-c").update_address_pong(
    relay_addr, now,
  )
  global_state.connection_manager = global_state.connection_manager.add_connection(
    direct_conn,
  )
  global_state.connection_manager = global_state.connection_manager.add_connection(
    relay_conn,
  )

  global_state.peer_manager = global_state.peer_manager.add_peer(
    PeerNode::new(id="node-b", version="", addresses=[direct_addr], metadata={}),
  )
  global_state.peer_manager = global_state.peer_manager.add_peer(
    PeerNode::new(id="node-c", version="", addresses=[relay_addr], metadata={}),
  )
  global_state.peer_manager = global_state.peer_manager.update_route(
    "node-b", "node-c", 2,
  )

  let transport = MockRouteTransport::{ sent: Ref::new([]) }
  register_transport(transport)

  let msg = Message::new(
    kind="http_proxy",
    source_id="node-a",
    target_id="node-b",
    body=@msgpack.string("x"),
    encrypted=false,
  )
  let (ok, protocol, route_addr) = send_message_now_with_route("node-b", msg)
  inspect(ok, content="true")
  inspect(protocol.unwrap_or(""), content="tcp")
  inspect(route_addr.unwrap_or(""), content="tcp://relay-hop:2000")
  inspect(transport.sent.val.length().to_string(), content="2")
  inspect(transport.sent.val[0], content="tcp://direct-target:1000")
  inspect(transport.sent.val[1], content="tcp://relay-hop:2000")
}

///|
async test "send_one_helper falls back to relay route for response" {
  app_state.config = Some({
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
  reset_route_test_state()

  let direct_addr = "tcp://direct-target:1000"
  let relay_addr = "tcp://relay-hop:2000"
  let now = @env.now()
  let relay_conn = Connection::new("node-a", "node-c").update_address_pong(
    relay_addr, now,
  )
  global_state.connection_manager = global_state.connection_manager.add_connection(
    relay_conn,
  )
  global_state.peer_manager = global_state.peer_manager.add_peer(
    PeerNode::new(id="node-b", version="", addresses=[direct_addr], metadata={}),
  )
  global_state.peer_manager = global_state.peer_manager.add_peer(
    PeerNode::new(id="node-c", version="", addresses=[relay_addr], metadata={}),
  )
  global_state.peer_manager = global_state.peer_manager.update_route(
    "node-b", "node-c", 2,
  )

  let transport = MockRouteTransport::{ sent: Ref::new([]) }
  register_transport(transport)

  let ok = send_one_helper(
    transport,
    direct_addr,
    "node-a",
    "tcp://127.0.0.1:19000",
    "node-b",
    "req-1",
    false,
    @msgpack.string("pong"),
    None,
  )
  inspect(ok, content="true")
  inspect(transport.sent.val.length().to_string(), content="2")
  inspect(transport.sent.val[0], content="tcp://direct-target:1000")
  inspect(transport.sent.val[1], content="tcp://relay-hop:2000")
}
