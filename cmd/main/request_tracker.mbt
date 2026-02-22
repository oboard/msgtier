///|
struct PendingRequest {
  cond : @cond_var.Cond
  headers : Map[String, String]
  mut response : Bytes?
  created_at : UInt64
}

///|
struct StreamRequest {
  queue : Array[Bytes]
  chunks : Map[Int, Bytes]
  mut next_index : Int
  mut total : Int?
  mut received : Int
  mut closed : Bool
  mut headers : Map[String, String]?
  mut headers_sent : Bool
  created_at : UInt64
}

///|
pub struct RequestTracker {
  pending : Map[String, PendingRequest]
}

///|
let global_request_tracker : RequestTracker = { pending: {} }

///|
let global_stream_requests : Ref[Map[String, StreamRequest]] = Ref::new({})

///|
fn add_pending_request(id : String) -> Unit {
  // Cleanup old requests if map gets too large (simple garbage collection)
  if global_request_tracker.pending.length() > 100 {
    let now = @env.now()
    let to_remove = []
    for k, v in global_request_tracker.pending {
      // Remove requests older than 60 seconds
      if now - v.created_at > 60000UL {
        to_remove.push(k)
      }
    }
    for k in to_remove {
      global_request_tracker.pending.remove(k)
    }
  }
  global_request_tracker.pending[id] = {
    cond: @cond_var.Cond::new(),
    headers: {},
    response: None,
    created_at: @env.now(),
  }
}

///|
fn add_stream_request(id : String) -> Unit {
  let streams = global_stream_requests.val
  if streams.length() > 100 {
    let now = @env.now()
    let to_remove = []
    for k, v in streams {
      if now - v.created_at > 60000UL || v.closed {
        to_remove.push(k)
      }
    }
    for k in to_remove {
      streams.remove(k)
    }
  }
  streams[id] = {
    queue: [],
    chunks: {},
    next_index: 0,
    total: None,
    received: 0,
    closed: false,
    headers: None,
    headers_sent: false,
    created_at: @env.now(),
  }
}

///|
fn is_stream_request(id : String) -> Bool {
  global_stream_requests.val.contains(id)
}

///|
fn push_stream_chunk(
  id : String,
  index : Int,
  total : Int,
  data : Bytes,
  headers : Map[String, String]?,
) -> Unit {
  let streams = global_stream_requests.val
  match streams.get(id) {
    Some(req) => {
      if total <= 0 {
        return
      }
      if req.total is None {
        req.total = Some(total)
      }
      match headers {
        Some(h) => if req.headers is None { req.headers = Some(h) }
        None => ()
      }
      if !req.chunks.contains(index) {
        req.chunks[index] = data
        req.received = req.received + 1
      }
      for {
        match req.chunks.get(req.next_index) {
          Some(chunk) => {
            req.queue.push(chunk)
            req.chunks.remove(req.next_index)
            req.next_index = req.next_index + 1
          }
          None => break ()
        }
      }
      match req.total {
        Some(t) => if req.received >= t { req.closed = true }
        None => ()
      }
    }
    None => ()
  }
}

///|
fn push_stream_data(
  id : String,
  data : Bytes,
  headers : Map[String, String]?,
) -> Unit {
  let streams = global_stream_requests.val
  match streams.get(id) {
    Some(req) => {
      match headers {
        Some(h) => if req.headers is None { req.headers = Some(h) }
        None => ()
      }
      req.queue.push(data)
      req.closed = true
    }
    None => ()
  }
}

///|
fn take_stream_chunk(id : String) -> (Bytes, Bool, Map[String, String]?)? {
  let streams = global_stream_requests.val
  match streams.get(id) {
    Some(req) =>
      if req.queue.length() > 0 {
        let chunk = req.queue[0]
        req.queue.remove(0) |> ignore
        let headers = if !req.headers_sent {
          req.headers_sent = true
          req.headers
        } else {
          None
        }
        let done = req.closed && req.queue.length() == 0
        if done {
          streams.remove(id)
        }
        Some((chunk, done, headers))
      } else if req.closed {
        streams.remove(id)
        let headers = if !req.headers_sent {
          req.headers_sent = true
          req.headers
        } else {
          None
        }
        Some((b"", true, headers))
      } else {
        None
      }
    None => None
  }
}

///|
fn resolve_request(
  id : String,
  headers : Map[String, String],
  response : Bytes,
) -> Unit {
  match global_request_tracker.pending.get(id) {
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
  match global_request_tracker.pending.get(id) {
    Some(req) => {
      let result = @async.with_timeout_opt(timeout_ms.reinterpret_as_int(), async fn() {
        for {
          match req.response {
            Some(r) => break (r, req.headers)
            None => @async.sleep(10)
          }
        }
      })
      global_request_tracker.pending.remove(id)
      result
    }
    None => {
      log_warn("RequestTracker: wait id=\{id} not found")
      None
    }
  }
}
