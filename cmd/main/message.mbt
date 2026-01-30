///|
struct Message {
  kind : String
  id : String
  addr : String
  version: String?
  peers : Array[NetworkAddress]?
  payload : String?
  target : String?
  data : String?
} derive(Show, ToJson, FromJson)

///|
fn Message::new(
  kind~ : String,
  id~ : String,
  addr~ : String,
  version? : String? = None,
  peers? : Array[NetworkAddress]? = None,
  payload? : String? = None,
  target? : String? = None,
  data? : String? = None,
) -> Message {
  { kind, id, addr, version, peers, payload, target, data }
}

///|
fn Message::to_msgpack(self : Message) -> Bytes {
  // Convert Message to msgpack Value
  let msg_map = Map::new()
  msg_map["kind"] = @msgpack.string(self.kind)
  msg_map["id"] = @msgpack.string(self.id)
  msg_map["addr"] = @msgpack.string(self.addr)
  match self.peers {
    Some(peers) => {
      let peers_array : Array[@msgpack.Value] = []
      for peer in peers {
        peers_array.push(@msgpack.string(peer.address))
      }
      msg_map["peers"] = @msgpack.array(peers_array)
    }
    None => msg_map["peers"] = @msgpack.nil()
  }
  match self.payload {
    Some(payload) => msg_map["payload"] = @msgpack.string(payload)
    None => msg_map["payload"] = @msgpack.nil()
  }
  match self.target {
    Some(target) => msg_map["target"] = @msgpack.string(target)
    None => msg_map["target"] = @msgpack.nil()
  }
  match self.data {
    Some(data) => msg_map["data"] = @msgpack.string(data)
    None => msg_map["data"] = @msgpack.nil()
  }
  @msgpack.encode(@msgpack.map(msg_map))
}

///|
fn Message::from_msgpack(msgpack : @msgpack.Value) -> Message raise {
  match msgpack {
    Map(
      { "id": String(id), "kind": String(kind), "addr": String(addr), .. } as msg_map
    ) => {
      let peers = match msg_map["peers"] {
        Array(arr) => {
          let peers_array : Array[NetworkAddress] = []
          for peer_value in arr {
            match peer_value {
              String(addr) =>
                peers_array.push(NetworkAddress::{ address: addr })
              _ => raise @msgpack.InvalidData("invalid peer address")
            }
          }
          Some(peers_array)
        }
        _ => None
      }
      let payload = match msg_map["payload"] {
        String(s) => Some(s)
        _ => None
      }
      let target = match msg_map["target"] {
        String(s) => Some(s)
        _ => None
      }
      let data = match msg_map["data"] {
        String(s) => Some(s)
        _ => None
      }
      let version = match msg_map["version"] {
        String(s) => Some(s)
        _ => None
      }
      Message::{ kind, id, addr, version, peers, payload, target, data }
    }
    _ => raise @msgpack.InvalidData("")
  }
}
