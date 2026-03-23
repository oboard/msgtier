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
) -> @msgpack.Value {
  port_forward_map([
    ("rule_id", @msgpack.string(rule_id)),
    ("protocol", @msgpack.string(protocol)),
    ("connection_id", @msgpack.string(connection_id)),
  ])
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
