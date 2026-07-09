///|
struct PendingRequest {
  cond : @cond_var.Cond
  headers : Map[String, String]
  mut response : Bytes?
  created_at : UInt64
}

///|
pub struct RequestTracker {
  pending : Map[String, PendingRequest]
}

///|
struct RequestTrackerState {
  tracker : RequestTracker
}

///|
let request_tracker_state : RequestTrackerState = { tracker: { pending: {} } }

///|
fn add_pending_request(id : String) -> Unit {
  // Cleanup old requests if map gets too large (simple garbage collection)
  if request_tracker_state.tracker.pending.length() > 100 {
    let now = @env.now()
    let to_remove = []
    for k, v in request_tracker_state.tracker.pending {
      // Remove requests older than 60 seconds
      if now - v.created_at > 60000UL {
        to_remove.push(k)
      }
    }
    for k in to_remove {
      request_tracker_state.tracker.pending.remove(k)
    }
  }
  request_tracker_state.tracker.pending[id] = {
    cond: @cond_var.Cond(),
    headers: {},
    response: None,
    created_at: @env.now(),
  }
}

///|
fn resolve_request(
  id : String,
  headers : Map[String, String],
  response : Bytes,
) -> Unit {
  match request_tracker_state.tracker.pending.get(id) {
    Some(req) => {
      req.response = Some(response)
      req.headers.merge_in_place(headers)
      req.cond.signal()
    }
    None => log_debug("RequestTracker: resolve id=\{id} not found")
  }
}

///|
async fn wait_for_response(
  id : String,
  timeout_ms : UInt,
) -> (Bytes, Map[String, String])? {
  match request_tracker_state.tracker.pending.get(id) {
    Some(req) => {
      let result = @async.with_timeout_opt(timeout_ms.reinterpret_as_int(), async fn() {
        for ;; {
          match req.response {
            Some(r) => break (r, req.headers)
            None => req.cond.wait()
          }
        }
      })
      request_tracker_state.tracker.pending.remove(id)
      result
    }
    None => {
      log_warn("RequestTracker: wait id=\{id} not found")
      None
    }
  }
}
