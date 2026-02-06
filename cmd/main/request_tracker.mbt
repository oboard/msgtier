///|
struct PendingRequest {
  cond : @cond_var.Cond
  mut response : String?
  created_at : UInt64
}

///|
pub struct RequestTracker {
  pending : Map[String, Ref[PendingRequest]]
}

///|
pub let global_request_tracker : RequestTracker = { pending: {} }

///|
pub fn add_pending_request(id : String) -> Unit {
  // Cleanup old requests if map gets too large (simple garbage collection)
  if global_request_tracker.pending.length() > 100 {
    let now = @env.now()
    let to_remove = []
    for k, v in global_request_tracker.pending {
      // Remove requests older than 60 seconds
      if now - v.val.created_at > 60000UL {
        to_remove.push(k)
      }
    }
    for k in to_remove {
      global_request_tracker.pending.remove(k)
    }
  }
  println("RequestTracker: add pending id=\{id}")
  global_request_tracker.pending[id] = Ref::new({
    cond: @cond_var.Cond::new(),
    response: None,
    created_at: @env.now(),
  })
}

///|
pub fn resolve_request(id : String, response : String) -> Unit {
  match global_request_tracker.pending.get(id) {
    Some(req) => {
      println("RequestTracker: resolve id=\{id}")
      req.val.response = Some(response)
      req.val.cond.signal()
    }
    None => println("RequestTracker: resolve id=\{id} not found")
  }
}

///|
pub async fn wait_for_response(id : String, timeout_ms : Int) -> String? {
  match global_request_tracker.pending.get(id) {
    Some(req) => {
      println("RequestTracker: wait start id=\{id} timeout_ms=\{timeout_ms}")
      let result = @async.with_timeout_opt(timeout_ms, fn() {
        for {
          match req.val.response {
            Some(r) => break r
            None => req.val.cond.wait()
          }
        }
      })
      global_request_tracker.pending.remove(id)
      match result {
        Some(_) => println("RequestTracker: wait done id=\{id}")
        None => println("RequestTracker: wait timeout id=\{id}")
      }
      result
    }
    None => {
      println("RequestTracker: wait id=\{id} not found")
      None
    }
  }
}
