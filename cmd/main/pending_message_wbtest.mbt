///|
fn reset_pending_state() -> Unit {
  pending_state.messages.clear()
  pending_state.send_times.clear()
}

///|
test "pending message attempt tracking" {
  reset_pending_state()
  let msg = Message::new(
    id="msg1",
    kind="test",
    source_id="src",
    target_id="dst",
  )
  add_pending_message(msg)
  let peer = "dst"

  let marked_tcp = mark_pending_message_attempted(msg.id, peer, "tcp")
  assert_eq(marked_tcp, true)
  let marked_udp = mark_pending_message_attempted(msg.id, peer, "udp")
  assert_eq(marked_udp, true)

  let pending = take_pending_messages(fn(_) { true })
  assert_eq(pending.length(), 1)
  assert_eq(pending[0].msg.id, msg.id)
  let target_protocols = pending[0].sent_targets.get(peer).unwrap()
  assert_eq(target_protocols.contains("tcp"), true)
  assert_eq(target_protocols.contains("udp"), true)
}

///|
test "remove pending message by id" {
  reset_pending_state()
  let msg = Message::new(
    id="msg2",
    kind="test",
    source_id="src",
    target_id="dst",
  )
  add_pending_message(msg)
  let removed = remove_pending_message_by_id("msg2")
  assert_eq(removed, true)
  let pending = take_pending_messages(fn(_) { true })
  assert_eq(pending.length(), 0)
}

///|
test "add pending broadcast message" {
  reset_pending_state()
  let msg = Message::new(id="msg3", kind="test", source_id="src")
  add_pending_message(msg)
  let pending = take_pending_messages(fn(_) { true })
  assert_eq(pending.length(), 1)
  assert_eq(pending[0].msg.is_broadcast(), true)
}
