///|
test "pending message redundancy" {
  clear_pending_messages()
  let msg = Message::new(
    id="msg1",
    kind="test",
    source_id="src",
    target_id="dst",
  )
  add_pending_message(msg)
  let required = ["tcp", "udp"]
  let peer = "dst"

  // Mark sent via TCP
  let removed1 = mark_pending_message_sent(msg.id, peer, "tcp", required)
  assert_eq(removed1, false)

  // Verify message still pending
  let pending1 = take_pending_messages(fn(_) { true })
  assert_eq(pending1.length(), 1)
  assert_eq(pending1[0].msg.id, msg.id)
  let target_protocols = pending1[0].sent_targets.get(peer).unwrap()
  assert_eq(target_protocols.contains("tcp"), true)
  assert_eq(target_protocols.contains("udp"), false)

  // Mark sent via UDP
  let removed2 = mark_pending_message_sent(msg.id, peer, "udp", required)
  assert_eq(removed2, true)

  // Verify message removed
  let pending2 = take_pending_messages(fn(_) { true })
  assert_eq(pending2.length(), 0)
}

///|
test "pending message redundancy partial" {
  clear_pending_messages()
  let msg = Message::new(
    id="msg2",
    kind="test",
    source_id="src",
    target_id="dst",
  )
  add_pending_message(msg)
  let required = ["tcp"]
  let peer = "dst"

  // Mark sent via TCP (should be enough)
  let removed1 = mark_pending_message_sent(msg.id, peer, "tcp", required)
  assert_eq(removed1, true)

  // Verify message removed
  let pending1 = take_pending_messages(fn(_) { true })
  assert_eq(pending1.length(), 0)
}

///|
test "remove pending message by id" {
  clear_pending_messages()
  let msg = Message::new(
    id="msg3",
    kind="test",
    source_id="src",
    target_id="dst",
  )
  add_pending_message(msg)
  let removed = remove_pending_message_by_id("msg3")
  assert_eq(removed, true)
  let pending = take_pending_messages(fn(_) { true })
  assert_eq(pending.length(), 0)
}

///|
test "set pending message broadcast" {
  clear_pending_messages()
  let msg = Message::new(
    id="msg4",
    kind="test",
    source_id="src",
    target_id="dst",
    broadcast=false,
  )
  add_pending_message(msg)
  set_pending_message_broadcast("msg4", true)
  let pending = take_pending_messages(fn(_) { true })
  assert_eq(pending.length(), 1)
  assert_eq(pending[0].msg.broadcast, true)
}
