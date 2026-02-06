///|
struct PendingMessage {
  target : String
  msg : Message
}

///|
let global_pending_messages : Ref[Array[PendingMessage]] = Ref::new([])

///|
pub fn add_pending_message(target : String, msg : Message) -> Unit {
  let pending = PendingMessage::{ target, msg }
  let messages = global_pending_messages.val
  messages.push(pending)
}

///|
pub fn get_pending_messages() -> Array[PendingMessage] {
  let messages = global_pending_messages.val
  if messages.is_empty() {
    []
  } else {
    // Clear the queue and return all messages
    global_pending_messages.val = []
    messages
  }
}
