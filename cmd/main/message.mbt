///|
struct Message {
  id : String
  kind : String
  from : String
  addr : String
  relay : Int // Relay depth: 1=direct, 2=relayed once, 3+=relayed multiple times
  visited : Array[String] // Track visited node IDs to prevent routing loops (DFS path tracking)
  version : String?
  peers : Array[NetworkAddress]?
  payload : String?
  target : String? // If set, relay to this address; if unset, process locally
  data : String?
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
  relay? : Int = 1,
  visited? : Array[String] = [],
  version? : String,
  peers? : Array[NetworkAddress],
  payload? : String,
  target? : String,
  data? : String,
  public_key? : String,
  secret_hash? : String,
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
    relay,
    visited,
    version,
    peers,
    payload,
    target,
    data,
    public_key,
    secret_hash,
    encrypted,
  }
}

///|
fn Message::to_msgpack(self : Message) -> Bytes {
  // Use fixed array structure for msgpack:
  // [id, kind, from, addr, relay, visited, encrypted, version, public_key, secret_hash, payload, target, data, peers]
  let visited_array : Array[@msgpack.Value] = []
  for node_id in self.visited {
    visited_array.push(@msgpack.string(node_id))
  }
  let values : Array[@msgpack.Value] = [
    @msgpack.string(self.id),
    @msgpack.string(self.kind),
    @msgpack.string(self.from),
    @msgpack.string(self.addr),
    @msgpack.int(self.relay),
    @msgpack.array(visited_array),
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
      // Support both old and new message formats for backwards compatibility
      // Old structure: [id, kind, from, addr, relay, encrypted, version, ...]
      // New structure: [id, kind, from, addr, relay, visited, encrypted, version, ...]
      if arr.length() < 6 {
        fail("Message array too short: expected at least 6 elements")
      }

      // Extract required fields (positions 0-4)
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

      // Extract relay (position 4, default 1 for direct connections)
      let relay = match arr[4] {
        Int(v) => v
        Nil => 1
        _ => fail("Invalid relay at position 4")
      }

      // Detect format by checking position 5:
      // - If it's an Array, it's the new format (visited field)
      // - If it's a Bool, it's the old format (encrypted field)
      let (visited, encrypted_pos) = match arr[5] {
        Array(_) => {
          // New format with visited field
          let visited_arr = match arr[5] {
            Array(visited_arr_val) => {
              let visited_list : Array[String] = []
              for visited_value in visited_arr_val {
                match visited_value {
                  String(node_id) => visited_list.push(node_id)
                  _ => fail("Invalid visited node ID in visited array")
                }
              }
              visited_list
            }
            _ => []
          }
          (visited_arr, 6)
        }
        Bool(_) | Nil =>
          // Old format without visited field - use empty array
          ([], 5)
        _ => fail("Invalid format at position 5: expected Array or Bool")
      }

      // Extract encrypted at the detected position
      let encrypted = match arr[encrypted_pos] {
        Bool(v) => v
        Nil => false
        _ => fail("Invalid encrypted at position \{encrypted_pos}")
      }

      // Extract optional fields, adjusting positions based on format
      let version_pos = encrypted_pos + 1
      let version = if arr.length() > version_pos {
        match arr[version_pos] {
          String(v) => Some(v)
          Nil => None
          _ => fail("Invalid version at position \{version_pos}")
        }
      } else {
        None
      }
      let public_key_pos = version_pos + 1
      let public_key = if arr.length() > public_key_pos {
        match arr[public_key_pos] {
          String(v) => Some(v)
          Nil => None
          _ => fail("Invalid public_key at position \{public_key_pos}")
        }
      } else {
        None
      }
      let secret_hash_pos = public_key_pos + 1
      let secret_hash = if arr.length() > secret_hash_pos {
        match arr[secret_hash_pos] {
          String(v) => Some(v)
          Nil => None
          _ => fail("Invalid secret_hash at position \{secret_hash_pos}")
        }
      } else {
        None
      }
      let payload_pos = secret_hash_pos + 1
      let payload = if arr.length() > payload_pos {
        match arr[payload_pos] {
          String(v) => Some(v)
          Nil => None
          _ => fail("Invalid payload at position \{payload_pos}")
        }
      } else {
        None
      }
      let target_pos = payload_pos + 1
      let target = if arr.length() > target_pos {
        match arr[target_pos] {
          String(v) => Some(v)
          Nil => None
          _ => fail("Invalid target at position \{target_pos}")
        }
      } else {
        None
      }
      let data_pos = target_pos + 1
      let data = if arr.length() > data_pos {
        match arr[data_pos] {
          String(v) => Some(v)
          Nil => None
          _ => fail("Invalid data at position \{data_pos}")
        }
      } else {
        None
      }
      let peers_pos = data_pos + 1
      let peers = if arr.length() > peers_pos {
        match arr[peers_pos] {
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
          _ => fail("Invalid peers at position \{peers_pos}")
        }
      } else {
        None
      }
      Message::{
        id,
        kind,
        from,
        addr,
        relay,
        visited,
        version,
        peers,
        payload,
        target,
        data,
        public_key,
        secret_hash,
        encrypted,
      }
    }
    _ => fail("Expected msgpack array, got \{msgpack.to_json().stringify()}")
  }
}
