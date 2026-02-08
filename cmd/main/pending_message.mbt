///|
pub struct PendingEntry {
  msg : Message
  sent_protocols : Map[String, Bool]
}

///|
let global_pending_messages : Array[PendingEntry] = []

///|
fn add_pending_message(msg : Message) -> Unit {
  let messages = global_pending_messages
  messages.push({ msg, sent_protocols: {} })
}

///|
fn take_pending_messages(predicate : (Message) -> Bool) -> Array[PendingEntry] {
  let messages = global_pending_messages
  if messages.is_empty() {
    []
  } else {
    let matched = []
    let now = @env.now()
    // Iterate backwards to safely remove expired messages
    let mut i = messages.length() - 1
    while i >= 0 {
      let entry = messages[i]
      // TTL Check (30s)
      if now > entry.msg.timestamp && now - entry.msg.timestamp > 30000 {
        messages.remove(i) |> ignore
      } else if predicate(entry.msg) {
        matched.push(entry)
      }
      i = i - 1
    }
    matched
  }
}

///|
fn remove_pending_message(message : Message) -> Bool {
  let len_before = global_pending_messages.length()
  global_pending_messages.retain(entry => entry.msg.id != message.id)
  let len_after = global_pending_messages.length()
  len_before != len_after
}

///|
/// Marks a message as sent via a specific protocol.
/// Returns true if the message has been sent via all required protocols and was removed.
fn mark_pending_message_sent(
  msg_id : String,
  protocol : String,
  required_protocols : Array[String],
) -> Bool {
  let messages = global_pending_messages
  for i = 0; i < messages.length(); i = i + 1 {
    let entry = messages[i]
    if entry.msg.id == msg_id {
      entry.sent_protocols[protocol] = true
      let mut all_sent = true
      for req in required_protocols {
        if !entry.sent_protocols.contains(req) {
          all_sent = false
          break
        }
      }
      if all_sent {
        messages.remove(i) |> ignore
        return true
      }
      return false
    }
  }
  false
}

///|
pub fn clear_pending_messages() -> Unit {
  global_pending_messages.clear()
}
