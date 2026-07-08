///|
fn port_forward_string_field(body : @msgpack.Value, key : String) -> String? {
  match body {
    Map(m) =>
      match m.get(key) {
        Some(String(v)) => Some(v)
        _ => None
      }
    _ => None
  }
}

///|
fn port_forward_bool_field(body : @msgpack.Value, key : String) -> Bool? {
  match body {
    Map(m) =>
      match m.get(key) {
        Some(Bool(v)) => Some(v)
        _ => None
      }
    _ => None
  }
}

///|
fn port_forward_int_field(body : @msgpack.Value, key : String) -> Int? {
  match body {
    Map(m) =>
      match m.get(key) {
        Some(Int(v)) => Some(v)
        Some(UInt32(v)) => Some(v.reinterpret_as_int())
        Some(UInt64(v)) => Some(v.to_int())
        _ => None
      }
    _ => None
  }
}

///|
fn port_forward_map(
  entries : Array[(String, @msgpack.Value)],
) -> @msgpack.Value {
  let m : Map[String, @msgpack.Value] = {}
  for entry in entries {
    m[entry.0] = entry.1
  }
  @msgpack.map(m)
}

///|
fn make_port_forward_open_body(
  rule_id : String,
  protocol : String,
  connection_id : String,
  target_host? : String = "",
  target_port? : Int = 0,
) -> @msgpack.Value {
  let fields : Array[(String, @msgpack.Value)] = [
    ("rule_id", @msgpack.string(rule_id)),
    ("protocol", @msgpack.string(protocol)),
    ("connection_id", @msgpack.string(connection_id)),
  ]
  if target_host != "" {
    fields.push(("target_host", @msgpack.string(target_host)))
  }
  if target_port > 0 {
    fields.push(("target_port", @msgpack.int(target_port)))
  }
  port_forward_map(fields)
}

///|
fn make_port_forward_open_ack_body(
  rule_id : String,
  protocol : String,
  connection_id : String,
  ok : Bool,
  error : String?,
) -> @msgpack.Value {
  let fields : Array[(String, @msgpack.Value)] = [
    ("rule_id", @msgpack.string(rule_id)),
    ("protocol", @msgpack.string(protocol)),
    ("connection_id", @msgpack.string(connection_id)),
    ("ok", @msgpack.bool(ok)),
  ]
  match error {
    Some(message) => fields.push(("error", @msgpack.string(message)))
    None => ()
  }
  port_forward_map(fields)
}

///|
fn make_port_forward_close_body(
  rule_id : String,
  protocol : String,
  connection_id : String,
  last_seq : Int?,
  error : String?,
) -> @msgpack.Value {
  let fields : Array[(String, @msgpack.Value)] = [
    ("rule_id", @msgpack.string(rule_id)),
    ("protocol", @msgpack.string(protocol)),
    ("connection_id", @msgpack.string(connection_id)),
  ]
  match last_seq {
    Some(seq) => fields.push(("last_seq", @msgpack.int(seq)))
    None => ()
  }
  match error {
    Some(message) => fields.push(("error", @msgpack.string(message)))
    None => ()
  }
  port_forward_map(fields)
}

///|
fn make_port_forward_data_body(
  rule_id : String,
  protocol : String,
  connection_id : String,
  seq : Int,
) -> @msgpack.Value {
  port_forward_map([
    ("rule_id", @msgpack.string(rule_id)),
    ("protocol", @msgpack.string(protocol)),
    ("connection_id", @msgpack.string(connection_id)),
    ("seq", @msgpack.int(seq)),
  ])
}

///|
/// Encode a `LocalPortEntry` for wire transport.
fn encode_local_port_entry(entry : LocalPortEntry) -> @msgpack.Value {
  let fields : Array[(String, @msgpack.Value)] = [
    ("protocol", @msgpack.string(entry.protocol)),
    ("bind_addr", @msgpack.string(entry.bind_addr)),
    ("port", @msgpack.int(entry.port)),
  ]
  match entry.process_name {
    Some(name) => fields.push(("process_name", @msgpack.string(name)))
    None => ()
  }
  port_forward_map(fields)
}

///|
/// Decode one msgpack-encoded `LocalPortEntry`. Returns None on malformed input.
fn decode_local_port_entry(value : @msgpack.Value) -> LocalPortEntry? {
  guard port_forward_string_field(value, "protocol") is Some(protocol) else {
    return None
  }
  guard port_forward_string_field(value, "bind_addr") is Some(bind_addr) else {
    return None
  }
  guard port_forward_int_field(value, "port") is Some(port) else { return None }
  let process_name = port_forward_string_field(value, "process_name")
  Some({ protocol, bind_addr, port, process_name })
}

///|
/// Decode an array of `LocalPortEntry` msgpack values.
///
/// Malformed elements are silently skipped so one bad entry doesn't wipe the
/// whole snapshot.
fn decode_local_port_entries(value : @msgpack.Value?) -> Array[LocalPortEntry] {
  let out : Array[LocalPortEntry] = []
  match value {
    Some(Array(items)) =>
      for item in items {
        match decode_local_port_entry(item) {
          Some(entry) => out.push(entry)
          None => ()
        }
      }
    _ => ()
  }
  out
}

///|
/// Fetch a nested `@msgpack.Value` array by top-level key.
fn port_forward_array_field(
  body : @msgpack.Value,
  key : String,
) -> @msgpack.Value? {
  match body {
    Map(m) =>
      match m.get(key) {
        Some(v) => Some(v)
        None => None
      }
    _ => None
  }
}

///|
/// `port_scan_snapshot` — full replacement for the peer's current view.
fn make_port_scan_snapshot_body(
  entries : Array[LocalPortEntry],
) -> @msgpack.Value {
  let items : Array[@msgpack.Value] = []
  for e in entries {
    items.push(encode_local_port_entry(e))
  }
  port_forward_map([
    ("version", @msgpack.int(1)),
    ("ports", @msgpack.array(items)),
  ])
}

///|
/// `port_scan_delta` — incremental update over the peer's current view.
fn make_port_scan_delta_body(
  added : Array[LocalPortEntry],
  removed : Array[LocalPortEntry],
) -> @msgpack.Value {
  let added_items : Array[@msgpack.Value] = []
  for e in added {
    added_items.push(encode_local_port_entry(e))
  }
  let removed_items : Array[@msgpack.Value] = []
  for e in removed {
    removed_items.push(encode_local_port_entry(e))
  }
  port_forward_map([
    ("version", @msgpack.int(1)),
    ("added", @msgpack.array(added_items)),
    ("removed", @msgpack.array(removed_items)),
  ])
}
