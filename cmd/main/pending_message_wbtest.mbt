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

  // Mark sent via TCP
  let removed1 = mark_pending_message_sent(msg.id, "tcp", required)
  assert_eq(removed1, false)

  // Verify message still pending
  let pending1 = take_pending_messages(fn(_) { true })
  assert_eq(pending1.length(), 1)
  assert_eq(pending1[0].msg.id, msg.id)
  assert_eq(pending1[0].sent_protocols.contains("tcp"), true)
  assert_eq(pending1[0].sent_protocols.contains("udp"), false)

  // Mark sent via UDP
  let removed2 = mark_pending_message_sent(msg.id, "udp", required)
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

  // Mark sent via TCP (should be enough)
  let removed1 = mark_pending_message_sent(msg.id, "tcp", required)
  assert_eq(removed1, true)

  // Verify message removed
  let pending1 = take_pending_messages(fn(_) { true })
  assert_eq(pending1.length(), 0)
}
