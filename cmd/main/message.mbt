///|
struct Message {
  id : String
  kind : String
  from : String
  addr : String
  version : String?
  peers : Array[NetworkAddress]?
  payload : String?
  target : String?
  data : String?
  relay : Int // 1 = direct, 2+ = relayed through N-1 peers
  public_key : String? // RSA public key for E2E encryption (sent in hello/welcome)
  encrypted : Bool // Whether the data field is encrypted
} derive(Show, ToJson, FromJson)

///|
fn Message::new(
  id? : String,
  kind~ : String,
  from~ : String,
  addr~ : String,
  version? : String? = None,
  peers? : Array[NetworkAddress]? = None,
  payload? : String? = None,
  target? : String? = None,
  data? : String? = None,
  relay? : Int = 1,
  public_key? : String? = None,
  encrypted? : Bool = false,
) -> Message {
  {
    id: id.unwrap_or(
      @uuidm.v4_with_rng(
        @uuidm.SimpleRng::new(@env.now().reinterpret_as_int64()),
      ).to_string_simple(),
    ),
    kind,
    from,
    addr,
    version,
    peers,
    payload,
    target,
    data,
    relay,
    public_key,
    encrypted,
  }
}

///|
fn Message::to_msgpack(self : Message) -> Bytes {
  // Convert Message to msgpack Value
  let msg_map = {
    "id": @msgpack.string(self.id),
    "kind": @msgpack.string(self.kind),
    "from": @msgpack.string(self.from),
    "addr": @msgpack.string(self.addr),
    "relay": @msgpack.int(self.relay),
    "encrypted": @msgpack.bool(self.encrypted),
  }
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
  match self.version {
    Some(version) => msg_map["version"] = @msgpack.string(version)
    None => msg_map["version"] = @msgpack.nil()
  }
  match self.public_key {
    Some(public_key) => msg_map["public_key"] = @msgpack.string(public_key)
    None => msg_map["public_key"] = @msgpack.nil()
  }
  @msgpack.encode(@msgpack.map(msg_map))
}

///|
fn Message::from_msgpack(msgpack : @msgpack.Value) -> Message raise {
  match msgpack {
    Map(
      {
        "id": String(id),
        "from": String(from),
        "kind": String(kind),
        "addr": String(addr),
        ..
      } as msg_map
    ) => {
      let peers = match msg_map {
        { "peers": Array(arr), .. } => {
          let peers_array : Array[NetworkAddress] = []
          for peer_value in arr {
            match peer_value {
              String(addr) =>
                peers_array.push(NetworkAddress::{ address: addr })
              _ => fail("invalid peer address")
            }
          }
          Some(peers_array)
        }
        _ => None
      }
      let payload = match msg_map {
        { "payload": String(s), .. } => Some(s)
        _ => None
      }
      let target = match msg_map {
        { "target": String(s), .. } => Some(s)
        _ => None
      }
      let data = match msg_map {
        { "data": String(s), .. } => Some(s)
        _ => None
      }
      let version = match msg_map {
        { "version": String(s), .. } => Some(s)
        _ => None
      }
      let relay = match msg_map {
        { "relay": Int(r), .. } => r
        _ => 1
      }
      let public_key = match msg_map {
        { "public_key": String(s), .. } => Some(s)
        _ => None
      }
      let encrypted = match msg_map {
        { "encrypted": Bool(b), .. } => b
        _ => false
      }
      Message::{
        id,
        kind,
        from,
        addr,
        version,
        peers,
        payload,
        target,
        data,
        relay,
        public_key,
        encrypted,
      }
    }
    _ => fail(msgpack.to_json().stringify())
  }
}
