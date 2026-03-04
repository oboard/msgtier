///|
pub struct PendingEntry {
  mut msg : Message
  sent_targets : Map[String, Map[String, Bool]] // PeerID -> Protocol -> Sent
  retry_count : Int
  last_attempt : UInt64
  acked_peers : Map[String, Bool]
}

///|
let global_pending_messages : Array[PendingEntry] = []

///|
let global_pending_cond : @cond_var.Cond = @cond_var.Cond::new()

///|
let global_pending_generation : Ref[Int] = Ref::new(0)

///|
let pending_send_times : Ref[Map[String, UInt64]] = Ref::new({})

///|
fn notify_pending_changed() -> Unit {
  global_pending_generation.val = global_pending_generation.val + 1
  global_pending_cond.signal()
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
pub fn should_send_message(
  msg_id : String,
  peer_id : String,
  protocol : String,
  min_interval_ms : UInt64,
) -> Bool {
  let now = @env.now()
  let key = make_send_key(msg_id, peer_id, protocol)
  match pending_send_times.val.get(key) {
    Some(last) => if now > last { now - last >= min_interval_ms } else { true }
    None => true
  }
}

///|
pub fn record_message_sent(
  msg_id : String,
  peer_id : String,
  protocol : String,
) -> Unit {
  let key = make_send_key(msg_id, peer_id, protocol)
  pending_send_times.val[key] = @env.now()
}

///|
fn clear_message_send_state(msg_id : String) -> Unit {
  let times = pending_send_times.val
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
pub fn add_pending_message(msg : Message) -> Unit {
  let messages = global_pending_messages
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
pub fn take_pending_messages(
  predicate : (PendingEntry) -> Bool,
) -> Array[PendingEntry] {
  let messages = global_pending_messages
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
pub fn remove_pending_message(message : Message) -> Bool {
  remove_pending_message_by_id(message.id)
}

///|
fn remove_pending_message_by_id(id : String) -> Bool {
  let len_before = global_pending_messages.length()
  global_pending_messages.retain(entry => entry.msg.id != id)
  let len_after = global_pending_messages.length()
  clear_message_send_state(id)
  if len_before != len_after {
    notify_pending_changed()
  }
  len_before != len_after
}

///|
pub fn mark_pending_message_sent(
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
        if entry.msg.kind == "ack" {
          messages.remove(i) |> ignore
          return true
        }
        return false
      }
      return false
    }
  }
  false
}

///|
pub fn clear_pending_messages() -> Unit {
  if !global_pending_messages.is_empty() {
    global_pending_messages.clear()
    notify_pending_changed()
  }
}

///|
pub fn get_pending_generation() -> Int {
  global_pending_generation.val
}

///|
pub async fn wait_for_pending_change(
  last_generation : Int,
  timeout_ms : Int,
) -> Int {
  ignore(
    @async.with_timeout_opt(timeout_ms, async fn() {
      for {
        if global_pending_generation.val != last_generation {
          break ()
        }
        global_pending_cond.wait()
      }
    }),
  )
  global_pending_generation.val
}

///|
pub fn is_pending_message(id : String) -> Bool {
  for entry in global_pending_messages {
    if entry.msg.id == id {
      return true
    }
  }
  false
}

///|
pub fn set_pending_message_broadcast(id : String) -> Unit {
  let messages = global_pending_messages
  for i = 0; i < messages.length(); i = i + 1 {
    if messages[i].msg.id == id {
      messages[i].msg = { ..messages[i].msg, target_id: None }
      notify_pending_changed()
      break
    }
  }
}

///|
pub fn mark_pending_message_acked(msg_id : String, peer_id : String) -> Unit {
  let messages = global_pending_messages
  let mut idx_to_remove = -1
  for i = 0; i < messages.length(); i = i + 1 {
    let entry = messages[i]
    if entry.msg.id == msg_id {
      entry.acked_peers[peer_id] = true
      match entry.msg.target_id {
        Some(tid) => if tid == peer_id { idx_to_remove = i }
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
pub fn update_pending_message_state(
  msg_id : String,
  retry_count : Int,
  last_attempt : UInt64,
) -> Unit {
  let messages = global_pending_messages
  for i = 0; i < messages.length(); i = i + 1 {
    if messages[i].msg.id == msg_id {
      let old = messages[i]
      messages[i] = { ..old, retry_count, last_attempt }
      break
    }
  }
}
