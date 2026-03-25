///|
struct MockReplyTransport {
  sent : Ref[Array[String]]
}

///|
impl Transport for MockReplyTransport with send(self, target, _data) {
  self.sent.val.push(target)
  true
}

///|
impl Transport for MockReplyTransport with listen(
  _self,
  _root,
  _handler,
  _on_disconnect,
) {
  ()
}

///|
impl Transport for MockReplyTransport with local_addr(_self) {
  "127.0.0.1:19001"
}

///|
impl Transport for MockReplyTransport with protocol(_self) {
  "tcp"
}

///|
impl Transport for MockReplyTransport with protocol_type(_self) {
  Tcp
}

///|
impl Transport for MockReplyTransport with local_address(_self) {
  Address::parse("tcp://127.0.0.1:19001") catch {
    _ => abort("invalid mock reply local address")
  }
}

///|
async test "handle_text_message replies via sender addr" {
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
  let transport = MockReplyTransport::{ sent: Ref::new([]) }
  let msg = Message::new(
    kind="text",
    source_id="node-a",
    target_id="node-b",
    body=@msgpack.string("hello"),
    payload="req-1",
    encrypted=false,
  )
  @async.with_task_group(async fn(root) {
    handle_text_message({
      root,
      transport,
      local_addr: "tcp://127.0.0.1:19001",
      sender_addr: "tcp://relay-hop:2000",
      my_id: "node-b",
      msg,
      should_skip_hello_callback: false,
    })
    @async.sleep(10)
  })
  inspect((transport.sent.val.length() > 0).to_string(), content="true")
  inspect(transport.sent.val[0], content="tcp://relay-hop:2000")
}
