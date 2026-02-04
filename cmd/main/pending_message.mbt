///|
struct PendingMessage {
  target : String
  msg : Message
  last_sent : UInt64
  retry_count : Int
  max_retries : Int
}

///|
let global_pending_messages : Ref[Array[PendingMessage]] = Ref::new([])

///|
pub fn add_pending_message(target : String, msg : Message) -> Unit {
  let now = @env.now()
  let pending = PendingMessage::{
    target,
    msg,
    last_sent: now,
    retry_count: 0,
    max_retries: 5,
  }
  let messages = global_pending_messages.val
  messages.push(pending)
}

///|
pub fn get_pending_messages() -> Array[PendingMessage] {
  let messages = global_pending_messages.val
  // Only return messages that should be processed now
  // (first attempt or retry eligible)
  let ready : Array[PendingMessage] = []
  let remaining : Array[PendingMessage] = []
  for pending in messages {
    let now = @env.now()
    let elapsed = now - pending.last_sent
    // Exponential backoff: 1s, 2s, 4s, 8s, 16s
    let backoff_ms = if pending.retry_count == 0 {
      0UL // Send immediately first time
    } else {
      let shift_amount = pending.retry_count.reinterpret_as_uint().to_uint64()
      (1UL << shift_amount.to_int()) * 1000UL
    }
    if elapsed >= backoff_ms && pending.retry_count <= pending.max_retries {
      // Mark as sent by updating the pending message
      let updated = PendingMessage::{
        ..pending,
        last_sent: now,
        retry_count: pending.retry_count + 1,
      }
      ready.push(updated)
    } else {
      remaining.push(pending)
    }
  }
  global_pending_messages.val = remaining
  ready
}
