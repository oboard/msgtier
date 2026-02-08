///|
struct PendingMessage {
  target : String
  msg : Message
}

///|
let global_pending_messages : Ref[Array[PendingMessage]] = Ref::new([])

///|
fn add_pending_message(target : String, msg : Message) -> Unit {
  let pending = PendingMessage::{ target, msg }
  let messages = global_pending_messages.val
  messages.push(pending)
}

///|
fn take_pending_messages(
  predicate : (PendingMessage) -> Bool,
) -> Array[PendingMessage] {
  let messages = global_pending_messages.val
  if messages.is_empty() {
    []
  } else {
    let matched = []
    let kept = []
    for msg in messages {
      if predicate(msg) {
        matched.push(msg)
      } else {
        kept.push(msg)
      }
    }
    global_pending_messages.val = kept
    matched
  }
}
