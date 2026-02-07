///|
struct ProxyMessage {
  op : String // "connect", "data", "close"
  conn_id : String
  target_addr : String?
  data : Bytes?
} derive(Show, ToJson, FromJson)

///|
fn ProxyMessage::to_msgpack(self : ProxyMessage) -> @msgpack.Value {
  let map_val = {
    "op" : @msgpack.string(self.op),
    "conn_id" : @msgpack.string(self.conn_id),
  }
  match self.target_addr {
    Some(addr) => map_val["target_addr"] = @msgpack.string(addr)
    None => ()
  }
  match self.data {
    Some(d) => map_val["data"] = @msgpack.binary(d)
    None => ()
  }
  @msgpack.map(map_val)
}

///|
fn ProxyMessage::from_msgpack(value : @msgpack.Value) -> ProxyMessage? {
  match value {
    Map(m) => {
      let op = match m.get("op") {
        Some(val) => match val {
          String(s) => s
          _ => return None
        }
        None => return None
      }
      let conn_id = match m.get("conn_id") {
        Some(val) => match val {
          String(s) => s
          _ => return None
        }
        None => return None
      }
      let target_addr = match m.get("target_addr") {
        Some(val) => match val {
          String(s) => Some(s)
          _ => None
        }
        None => None
      }
      let data = match m.get("data") {
        Some(val) => match val {
          Binary(b) => Some(b)
          _ => None
        }
        None => None
      }
      Some({ op, conn_id, target_addr, data })
    }
    _ => None
  }
}
