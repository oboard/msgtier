///|
pub struct PendingEntry {
  mut msg : Message
  sent_targets : Map[String, Map[String, Bool]] // PeerID -> Protocol -> Sent
}

///|
let global_pending_messages : Array[PendingEntry] = []

///|
fn add_pending_message(msg : Message) -> Unit {
  let messages = global_pending_messages
  // Optimization: If adding a "sync" message, remove any existing "sync" messages
  // destined for the same target (or broadcast). The new sync contains the latest state.
  if msg.kind == "sync" {
    messages.retain(fn(entry) {
      entry.msg.kind != "sync" || entry.msg.target_id != msg.target_id
    })
  }
  messages.push({ msg, sent_targets: {} })
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
      // TTL Check (30s or custom timeout)
      let timeout = entry.msg.timeout_ms.unwrap_or(30000UL)
      if now > entry.msg.timestamp && now - entry.msg.timestamp > timeout {
        log_debug(
          "Pending message \{entry.msg.id} timed out (age: \{now - entry.msg.timestamp}ms > \{timeout}ms), removed",
        )
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
  remove_pending_message_by_id(message.id)
}

///|
fn remove_pending_message_by_id(id : String) -> Bool {
  let len_before = global_pending_messages.length()
  global_pending_messages.retain(entry => entry.msg.id != id)
  let len_after = global_pending_messages.length()
  len_before != len_after
}

///|
/// Marks a message as sent via a specific protocol to a specific peer.
/// Returns true if the message has been sent via all required protocols and was removed.
fn mark_pending_message_sent(
  msg_id : String,
  peer_id : String,
  protocol : String,
  required_protocols : Array[String],
) -> Bool {
  let messages = global_pending_messages
  for i = 0; i < messages.length(); i = i + 1 {
    let entry = messages[i]
    if entry.msg.id == msg_id {
      let target_protocols = match entry.sent_targets.get(peer_id) {
        Some(m) => m
        None => {
          let m = {}
          entry.sent_targets[peer_id] = m
          m
        }
      }
      target_protocols[protocol] = true

      // If broadcast, do not remove (rely on TTL to keep sending to other peers)
      if entry.msg.is_broadcast() {
        return false
      }
      let mut all_sent = true
      for req in required_protocols {
        if !target_protocols.contains(req) {
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

///|
pub fn set_pending_message_broadcast(id : String) -> Unit {
  let messages = global_pending_messages
  for i = 0; i < messages.length(); i = i + 1 {
    if messages[i].msg.id == id {
      messages[i].msg = { ..messages[i].msg, target_id: None }
      break
    }
  }
}
