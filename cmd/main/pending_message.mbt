///|
struct PendingMessage {
  target : String
  msg : Message
} derive(Show, Eq)

///|
let global_pending_messages : Array[PendingMessage] = []

///|
fn add_pending_message(target : String, msg : Message) -> Unit {
  let pending = PendingMessage::{ target, msg }
  let messages = global_pending_messages
  messages.push(pending)
}

///|
fn take_pending_messages(
  predicate : (PendingMessage) -> Bool,
) -> Array[PendingMessage] {
  let messages = global_pending_messages
  if messages.is_empty() {
    []
  } else {
    let matched = []
    for msg in messages {
      if predicate(msg) {
        matched.push(msg)
      }
    }
    matched
  }
}

///|
fn remove_pending_message(message : PendingMessage) -> Unit {
  global_pending_messages.retain(pm => pm != message)
}
