///|
let global_pending_messages : Array[Message] = []

///|
fn add_pending_message(msg : Message) -> Unit {
  let messages = global_pending_messages
  messages.push(msg)
}

///|
fn take_pending_messages(predicate : (Message) -> Bool) -> Array[Message] {
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
fn remove_pending_message(message : Message) -> Unit {
  global_pending_messages.retain(msg => msg != message)
}
