///|
pub struct PendingEntry {
  msg : Message
  sent_targets : Map[String, Map[String, Bool]] // PeerID -> Protocol -> Sent
  retry_count : Int
  last_attempt : UInt64
  acked_peers : Map[String, Bool]
}

///|
struct PendingState {
  messages : Array[PendingEntry]
  cond : @cond_var.Cond
  mut generation : Int
  send_times : Map[String, UInt64]
}

///|
let pending_state : PendingState = {
  messages: [],
  cond: @cond_var.Cond::new(),
  generation: 0,
  send_times: {},
}

///|
fn notify_pending_changed() -> Unit {
  pending_state.generation = pending_state.generation + 1
  pending_state.cond.signal()
}

///|
fn make_send_key(
  msg_id : String,
  peer_id : String,
  protocol : String,
) -> String {
  msg_id + "|" + peer_id + "|" + protocol
}

///|
fn should_send_message(
  msg_id : String,
  peer_id : String,
  protocol : String,
  min_interval_ms : UInt64,
) -> Bool {
  let now = @env.now()
  let key = make_send_key(msg_id, peer_id, protocol)
  match pending_state.send_times.get(key) {
    Some(last) => if now > last { now - last >= min_interval_ms } else { true }
    None => true
  }
}

///|
fn record_message_sent(
  msg_id : String,
  peer_id : String,
  protocol : String,
) -> Unit {
  let key = make_send_key(msg_id, peer_id, protocol)
  pending_state.send_times[key] = @env.now()
}

///|
fn clear_message_send_state(msg_id : String) -> Unit {
  let times = pending_state.send_times
  let keys = []
  for k, _ in times {
    if k.has_prefix(msg_id + "|") {
      keys.push(k)
    }
  }
  for k in keys {
    times.remove(k)
  }
}

///|
fn add_pending_message(msg : Message) -> Unit {
  let messages = pending_state.messages
  if msg.kind == "sync" {
    messages.retain(fn(entry) {
      entry.msg.kind != "sync" || entry.msg.target_id != msg.target_id
    })
  }
  messages.push({
    msg,
    sent_targets: {},
    retry_count: 0,
    last_attempt: 0UL,
    acked_peers: {},
  })
  notify_pending_changed()
}

///|
fn take_pending_messages(
  predicate : (PendingEntry) -> Bool,
) -> Array[PendingEntry] {
  let messages = pending_state.messages
  if messages.is_empty() {
    []
  } else {
    let matched = []
    let now = @env.now()
    let mut i = messages.length() - 1
    while i >= 0 {
      let entry = messages[i]
      let timeout = entry.msg.timeout_ms.unwrap_or(30000U)
      let timeout_u64 = timeout.to_uint64()
      if now > entry.msg.timestamp && now - entry.msg.timestamp > timeout_u64 {
        log_debug(
          "Pending message \{entry.msg.id} timed out (age: \{now - entry.msg.timestamp}ms > \{timeout}ms), removed",
        )
        messages.remove(i) |> ignore
      } else if predicate(entry) {
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
  let len_before = pending_state.messages.length()
  pending_state.messages.retain(entry => entry.msg.id != id)
  let len_after = pending_state.messages.length()
  clear_message_send_state(id)
  if len_before != len_after {
    notify_pending_changed()
  }
  len_before != len_after
}

///|
fn mark_pending_message_attempted(
  msg_id : String,
  peer_id : String,
  protocol : String,
) -> Bool {
  let messages = pending_state.messages
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
      return true
    }
  }
  false
}

///|
fn get_pending_generation() -> Int {
  pending_state.generation
}

///|
async fn wait_for_pending_change(
  last_generation : Int,
  timeout_ms : Int,
) -> Int {
  ignore(
    @async.with_timeout_opt(timeout_ms, async fn() {
      for ;; {
        if pending_state.generation != last_generation {
          break ()
        }
        pending_state.cond.wait()
      }
    }),
  )
  pending_state.generation
}

///|
fn is_pending_message(id : String) -> Bool {
  for entry in pending_state.messages {
    if entry.msg.id == id {
      return true
    }
  }
  false
}

///|
fn mark_pending_message_acked(msg_id : String, peer_id : String) -> Unit {
  let messages = pending_state.messages
  let mut idx_to_remove = -1
  for i = 0; i < messages.length(); i = i + 1 {
    let entry = messages[i]
    if entry.msg.id == msg_id {
      entry.acked_peers[peer_id] = true
      match entry.msg.target_id {
        Some(tid) =>
          // ACK only confirms receipt. For request/response messages (payload present),
          // keep pending until actual response or timeout.
          if tid == peer_id && entry.msg.payload is None {
            idx_to_remove = i
          }
        None => ()
      }
      break
    }
  }
  if idx_to_remove != -1 {
    messages.remove(idx_to_remove) |> ignore
    clear_message_send_state(msg_id)
    notify_pending_changed()
  }
}

///|
fn update_pending_message_state(
  msg_id : String,
  retry_count : Int,
  last_attempt : UInt64,
) -> Unit {
  let messages = pending_state.messages
  for i = 0; i < messages.length(); i = i + 1 {
    if messages[i].msg.id == msg_id {
      let old = messages[i]
      messages[i] = { ..old, retry_count, last_attempt }
      break
    }
  }
}
