///|
struct Message {
  id : String
  kind : String
  source_id : String
  source_addr : String?
  relay : Int // Relay depth: 1=direct, 2=relayed once, 3+=relayed multiple times
  visited : Array[String] // Track visited node IDs to prevent routing loops (DFS path tracking)
  version : String?
  peers : Array[NetworkAddress]?
  payload : String?
  target_id : String? // If set, send to this peer; if unset, broadcast
  body : @msgpack.Value
  public_key : Bytes? // X25519 public key for E2E encryption (sent in hello/welcome)
  secret_hash : String? // Hash of network secret for authentication
  encrypted : Bool // Whether the data field is encrypted
  broadcast : Bool // Whether this message should be broadcast to all peers
  timestamp : UInt64 // Creation timestamp for TTL and deduplication
  timeout_ms : UInt64? // Optional custom timeout in milliseconds
} derive(Show, Eq)

///|
let message_id_counter : Ref[Int] = Ref::new(0)

///|
fn Message::new(
  id? : String,
  kind~ : String,
  source_id~ : String,
  source_addr? : String,
  relay? : Int = 1,
  visited? : Array[String] = [],
  version? : String,
  peers? : Array[NetworkAddress],
  payload? : String,
  target_id? : String,
  body? : @msgpack.Value = @msgpack.nil(),
  public_key? : Bytes,
  secret_hash? : String,
  encrypted? : Bool = false,
  broadcast? : Bool = false,
  timestamp? : UInt64,
  timeout_ms? : UInt64,
) -> Message {
  message_id_counter.val += 1
  {
    id: id.unwrap_or(
      @uuidm.v4_with_rng(
        @uuidm.SimpleRng::new(
          @env.now().reinterpret_as_int64() + message_id_counter.val.to_int64(),
        ),
      ).to_string_simple(),
    ),
    kind,
    source_id,
    source_addr,
    relay,
    visited,
    version,
    peers,
    payload,
    target_id,
    body,
    public_key,
    secret_hash,
    encrypted,
    broadcast,
    timestamp: timestamp.unwrap_or(@env.now()),
    timeout_ms,
  }
}

///|
fn Message::to_msgpack(self : Message) -> Bytes {
  // Use fixed array structure for msgpack:
  // [id, kind, from, addr, relay, visited, encrypted, version, public_key, secret_hash, payload, target, data, peers, broadcast, timestamp, timeout_ms]
  let visited_array : Array[@msgpack.Value] = []
  for peer_id in self.visited {
    visited_array.push(@msgpack.string(peer_id))
  }
  let values : Array[@msgpack.Value] = [
    @msgpack.string(self.id),
    @msgpack.string(self.kind),
    @msgpack.string(self.source_id),
    match self.source_addr {
      Some(addr) => @msgpack.string(addr)
      None => @msgpack.nil()
    },
    @msgpack.int(self.relay),
    @msgpack.array(visited_array),
    @msgpack.bool(self.encrypted), // Always set encrypted field (might be true if message is encrypted)
    match self.version {
      Some(v) => @msgpack.string(v)
      None => @msgpack.nil()
    },
    match self.public_key {
      Some(pk) => @msgpack.binary(pk)
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
    match self.target_id {
      Some(t) => @msgpack.string(t)
      None => @msgpack.nil()
    },
    self.body,
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
    @msgpack.bool(self.broadcast),
    @msgpack.uint64(self.timestamp),
    match self.timeout_ms {
      Some(t) => @msgpack.uint64(t)
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
      // New structure: [id, kind, from, addr, relay, visited, encrypted, version, ..., timestamp]
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
      let source_id = match arr[2] {
        String(v) => v
        _ => fail("Invalid or missing from at position 2")
      }
      let source_addr = match arr[3] {
        String(v) => Some(v)
        Nil => None
        _ => fail("Invalid or missing addr at position 3")
      }

      // Extract relay (position 4, default 1 for direct connections)
      let relay = match arr[4] {
        Int(v) => v
        Nil => 1
        _ => fail("Invalid relay at position 4")
      }

      // Extract visited (position 5)
      let visited = match arr[5] {
        Array(visited_arr_val) => {
          let visited_list : Array[String] = []
          for visited_value in visited_arr_val {
            match visited_value {
              String(peer_id) => visited_list.push(peer_id)
              _ => fail("Invalid visited node ID in visited array")
            }
          }
          visited_list
        }
        Nil => []
        _ => fail("Invalid visited at position 5")
      }

      // Extract encrypted (position 6)
      let encrypted = match arr[6] {
        Bool(v) => v
        Nil => false
        _ => fail("Invalid encrypted at position 6")
      }

      // Extract optional fields
      let version_pos = 7
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
          Binary(v) => Some(v)
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
      let target_id = if arr.length() > target_pos {
        match arr[target_pos] {
          String(v) => Some(v)
          Nil => None
          _ => fail("Invalid target at position \{target_pos}")
        }
      } else {
        None
      }
      let body_pos = target_pos + 1
      let body = if arr.length() > body_pos {
        arr[body_pos]
      } else {
        @msgpack.nil()
      }
      let peers_pos = body_pos + 1
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
      let broadcast_pos = peers_pos + 1
      let broadcast = if arr.length() > broadcast_pos {
        match arr[broadcast_pos] {
          Bool(v) => v
          Nil => false
          _ => fail("Invalid broadcast at position \{broadcast_pos}")
        }
      } else {
        false
      }
      let timestamp_pos = broadcast_pos + 1
      let timestamp = if arr.length() > timestamp_pos {
        match arr[timestamp_pos] {
          UInt64(v) => v
          Int(v) => v.to_uint64()
          _ => @env.now()
        }
      } else {
        @env.now()
      }
      let timeout_ms_pos = timestamp_pos + 1
      let timeout_ms = if arr.length() > timeout_ms_pos {
        match arr[timeout_ms_pos] {
          UInt64(v) => Some(v)
          Int(v) => Some(v.to_uint64())
          Nil => None
          _ => None
        }
      } else {
        None
      }
      Message::{
        id,
        kind,
        source_id,
        source_addr,
        relay,
        visited,
        version,
        peers,
        payload,
        target_id,
        body,
        public_key,
        secret_hash,
        encrypted,
        broadcast,
        timestamp,
        timeout_ms,
      }
    }
    _ => fail("Expected msgpack array, got \{msgpack.to_json().stringify()}")
  }
}
