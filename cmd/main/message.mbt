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
  public_key : String? // X25519 public key for E2E encryption (sent in hello/welcome)
  secret_hash : String? // Hash of network secret for authentication
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
  secret_hash? : String? = None,
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
    secret_hash,
    encrypted,
  }
}

///|
fn Message::to_msgpack(self : Message) -> Bytes {
  // Use fixed array structure for msgpack:
  // [id, kind, from, addr, relay, encrypted, version, public_key, secret_hash, payload, target, data, peers]
  let values : Array[@msgpack.Value] = [
    @msgpack.string(self.id),
    @msgpack.string(self.kind),
    @msgpack.string(self.from),
    @msgpack.string(self.addr),
    @msgpack.int(self.relay),
    @msgpack.bool(self.encrypted),
    match self.version {
      Some(v) => @msgpack.string(v)
      None => @msgpack.nil()
    },
    match self.public_key {
      Some(pk) => @msgpack.string(pk)
      None => @msgpack.nil()
    },
    match self.secret_hash {
      Some(sh) => @msgpack.string(sh)
      None => @msgpack.nil()
    },
    match self.payload {
      Some(p) => @msgpack.string(p)
      None => @msgpack.nil()
    },
    match self.target {
      Some(t) => @msgpack.string(t)
      None => @msgpack.nil()
    },
    match self.data {
      Some(d) => @msgpack.string(d)
      None => @msgpack.nil()
    },
    match self.peers {
      Some(peers) => {
        let peers_array : Array[@msgpack.Value] = []
        for peer in peers {
          peers_array.push(@msgpack.string(peer.address))
        }
        @msgpack.array(peers_array)
      }
      None => @msgpack.nil()
    },
  ]
  @msgpack.encode(@msgpack.array(values))
}

///|
fn Message::from_msgpack(msgpack : @msgpack.Value) -> Message raise {
  match msgpack {
    Array(arr) => {
      // Fixed array structure: [id, kind, from, addr, relay, encrypted, version, public_key, secret_hash, payload, target, data, peers]
      if arr.length() < 6 {
        fail("Message array too short: expected at least 6 elements")
      }

      // Extract required fields (positions 0-3)
      let id = match arr[0] {
        String(v) => v
        _ => fail("Invalid or missing id at position 0")
      }
      let kind = match arr[1] {
        String(v) => v
        _ => fail("Invalid or missing kind at position 1")
      }
      let from = match arr[2] {
        String(v) => v
        _ => fail("Invalid or missing from at position 2")
      }
      let addr = match arr[3] {
        String(v) => v
        _ => fail("Invalid or missing addr at position 3")
      }

      // Extract relay (position 4, default 1)
      let relay = match arr[4] {
        Int(v) => v
        Nil => 1
        _ => fail("Invalid relay at position 4")
      }

      // Extract encrypted (position 5, default false)
      let encrypted = match arr[5] {
        Bool(v) => v
        Nil => false
        _ => fail("Invalid encrypted at position 5")
      }

      // Extract optional fields (positions 6-12)
      let version = if arr.length() > 6 {
        match arr[6] {
          String(v) => Some(v)
          Nil => None
          _ => fail("Invalid version at position 6")
        }
      } else {
        None
      }
      let public_key = if arr.length() > 7 {
        match arr[7] {
          String(v) => Some(v)
          Nil => None
          _ => fail("Invalid public_key at position 7")
        }
      } else {
        None
      }
      let secret_hash = if arr.length() > 8 {
        match arr[8] {
          String(v) => Some(v)
          Nil => None
          _ => fail("Invalid secret_hash at position 8")
        }
      } else {
        None
      }
      let payload = if arr.length() > 9 {
        match arr[9] {
          String(v) => Some(v)
          Nil => None
          _ => fail("Invalid payload at position 9")
        }
      } else {
        None
      }
      let target = if arr.length() > 10 {
        match arr[10] {
          String(v) => Some(v)
          Nil => None
          _ => fail("Invalid target at position 10")
        }
      } else {
        None
      }
      let data = if arr.length() > 11 {
        match arr[11] {
          String(v) => Some(v)
          Nil => None
          _ => fail("Invalid data at position 11")
        }
      } else {
        None
      }
      let peers = if arr.length() > 12 {
        match arr[12] {
          Array(peers_arr) => {
            let peers_array : Array[NetworkAddress] = []
            for peer_value in peers_arr {
              match peer_value {
                String(peer_addr) =>
                  peers_array.push(NetworkAddress::{ address: peer_addr })
                _ => fail("Invalid peer address in peers array")
              }
            }
            Some(peers_array)
          }
          Nil => None
          _ => fail("Invalid peers at position 12")
        }
      } else {
        None
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
        secret_hash,
        encrypted,
      }
    }
    _ => fail("Expected msgpack array, got \{msgpack.to_json().stringify()}")
  }
}
