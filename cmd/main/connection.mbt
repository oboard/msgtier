///|
/// Connection represents a network connection to a peer
/// Each peer can have multiple connections (e.g., multiple network interfaces, redundant paths)
struct Connection {
  id : String
  peer_id : String
  last_seen : UInt64 // timestamp
  quality : Int // connection quality metric (0-100)
  relay : Int // 1 = direct, 2+ = relayed through N-1 peers
  metadata : Map[String, String]?
  latency_ms : Int? // Latest RTT in milliseconds (null if no pings yet)
  bandwidth_mbps : Double // Calculated bandwidth in Mbps
  packet_loss_rate : Int // Packet loss percentage (0-100)
  latency_history : Array[Int] // Recent RTT samples (last 20, approx 1 minute)
  packets_sent : Int // Total pings sent
  packets_lost : Int // Pings without pong response
  bytes_sent : UInt64 // Total bytes sent through connection
  bytes_received : UInt64 // Total bytes received
  last_ping_time : UInt64? // Timestamp when last ping was sent
  version : String // Version of the peer
  nat_type : NatType
  session_id : String? // Unique session ID for the connection
} derive(Show, ToJson, FromJson)

///|
enum NatType {
  NoNAT
  Symmetric
  FullCone
  Restricted
  PortRestricted
  Unknown
} derive(Show, ToJson, FromJson, Eq)

///|

///|
fn Connection::new(
  my_id : String,
  peer_id : String,
  session_id? : String,
) -> Connection {
  let (id1, id2) = if my_id < peer_id {
    (my_id, peer_id)
  } else {
    (peer_id, my_id)
  }
  let normalized_session = match session_id {
    Some(sid) => if sid.is_empty() { None } else { Some(sid) }
    None => None
  }
  let raw_id = match normalized_session {
    Some(sid) => "\{id1}:\{id2}:\{sid}"
    None => "\{id1}:\{id2}"
  }
  let id = bytes_to_hex(Bytes::from_array(@crypto.sha256(@utf8.encode(raw_id))))

  {
    id,
    peer_id,
    last_seen: @env.now(),
    quality: 0,
    relay: 1,
    metadata: None,
    latency_ms: None,
    bandwidth_mbps: 0.0,
    packet_loss_rate: 0,
    latency_history: [],
    packets_sent: 0,
    packets_lost: 0,
    bytes_sent: 0UL,
    bytes_received: 0UL,
    last_ping_time: None,
    version: "",
    nat_type: Unknown,
    session_id: normalized_session,
  }
}

///|
fn extract_host(addr : String) -> String {
  let s = if addr.contains("://") {
    let parts = addr.split("://").to_array()
    if parts.length() > 1 {
      parts[1].to_string()
    } else {
      addr
    }
  } else {
    addr
  }
  if s.has_prefix("[") {
    let mut end_idx = -1
    let mut i = 0
    for c in s {
      if c == ']' {
        end_idx = i
        break
      }
      i = i + 1
    }
    if end_idx != -1 {
      s[1:end_idx].to_string() catch {
        _ => s
      }
    } else {
      s
    }
  } else {
    let mut colons = 0
    for c in s {
      if c == ':' {
        colons = colons + 1
      }
    }
    if colons > 1 {
      s // IPv6 without brackets
    } else if colons == 1 {
      let parts = s.split(":").to_array()
      parts[0].to_string()
    } else {
      s
    }
  }
}

///|
fn is_loopback(ip : String) -> Bool {
  ip == "localhost" ||
  ip.has_prefix("127.") ||
  ip == "::1" ||
  ip == "0:0:0:0:0:0:0:1"
}

///|
fn is_private(ip : String) -> Bool {
  if ip.has_prefix("10.") {
    return true
  }
  if ip.has_prefix("192.168.") {
    return true
  }
  if ip.has_prefix("172.") {
    let parts = ip.split(".").to_array()
    if parts.length() > 1 {
      match parse_int_simple(parts[1].to_string()) {
        Some(v) => return v >= 16 && v <= 31
        None => return false
      }
    }
  }
  // IPv6 ULA (Unique Local Address) fc00::/7
  if ip.has_prefix("fc") || ip.has_prefix("fd") {
    return true
  }
  false
}

///|
fn parse_int_simple(s : String) -> Int? {
  let mut res = 0
  for c in s {
    if c < '0' || c > '9' {
      return None
    }
    res = res * 10 + (c.to_int() - '0'.to_int())
  }
  Some(res)
}

///|
fn Connection::update_relay(self : Connection, relay_depth : Int) -> Connection {
  { ..self, relay: relay_depth }
}

///|
fn Connection::update_session_id(
  self : Connection,
  session_id : String?,
) -> Connection {
  { ..self, session_id, }
}

///|
///  // This function is used for connection health monitoring
fn Connection::update_last_seen(
  self : Connection,
  timestamp : UInt64,
) -> Connection {
  { ..self, last_seen: timestamp }
}

///|
fn Connection::calculate_packet_loss(self : Connection) -> Int {
  if self.packets_sent == 0 {
    0
  } else {
    self.packets_lost * 100 / self.packets_sent
  }
}

///|
fn Connection::calculate_bandwidth_mbps(
  self : Connection,
  elapsed_ms : UInt64,
) -> Double {
  if elapsed_ms == 0UL {
    0.0
  } else {
    let bytes_in_mb = self.bytes_received.reinterpret_as_int64().to_double() /
      1_000_000.0
    let seconds = elapsed_ms.reinterpret_as_int64().to_double() / 1000.0
    bytes_in_mb / seconds
  }
}

///|
fn Connection::update_last_ping_time(
  self : Connection,
  time : UInt64?,
) -> Connection {
  { ..self, last_ping_time: time }
}

///|
fn Connection::to_msgpack(self : Connection) -> @msgpack.Value {
  @msgpack.array([
    @msgpack.string(self.peer_id),
    @msgpack.nil(),
    @msgpack.int(self.relay),
    match self.latency_ms {
      Some(l) => @msgpack.int(l)
      None => @msgpack.nil()
    },
    @msgpack.float(self.bandwidth_mbps),
    @msgpack.int(self.packet_loss_rate),
    @msgpack.string(self.id),
    @msgpack.nil(),
    @msgpack.nil(),
    @msgpack.uint64(self.last_seen),
    @msgpack.int(self.quality),
    match self.metadata {
      Some(m) => {
        let map_val = {}
        for k, v in m {
          map_val[k] = @msgpack.string(v)
        }
        @msgpack.map(map_val)
      }
      None => @msgpack.nil()
    },
    @msgpack.array(self.latency_history.map(@msgpack.int)),
    @msgpack.int(self.packets_sent),
    @msgpack.int(self.packets_lost),
    @msgpack.uint64(self.bytes_sent),
    @msgpack.uint64(self.bytes_received),
    match self.last_ping_time {
      Some(t) => @msgpack.uint64(t)
      None => @msgpack.nil()
    },
    @msgpack.string(self.version),
    @msgpack.string(self.nat_type.to_string()),
    match self.session_id {
      Some(sid) => @msgpack.string(sid)
      None => @msgpack.nil()
    },
  ])
}

///|
fn Connection::from_msgpack(msgpack : @msgpack.Value) -> Connection? {
  match msgpack {
    Array(
      [
        String(peer_id),
        _,
        Int(relay),
        latency_val,
        Float(bandwidth_mbps),
        Int(packet_loss_rate),
        String(id),
        _,
        protocol_val,
        UInt64(last_seen),
        Int(quality),
        metadata_val,
        Array(latency_history_val),
        Int(packets_sent),
        Int(packets_lost),
        UInt64(bytes_sent),
        UInt64(bytes_received),
        last_ping_time_val,
        String(version),
        String(nat_type_str),
        session_id_val,
      ]
    ) => {
      let nat_type = match nat_type_str {
        "NoNAT" => NoNAT
        "Symmetric" => Symmetric
        "FullCone" => FullCone
        "Restricted" => Restricted
        "PortRestricted" => PortRestricted
        "Unknown" => Unknown
        _ => Unknown
      }
      let latency_ms = match latency_val {
        Int(l) => Some(l)
        _ => None
      }
      let _ = match protocol_val {
        String(_) => ()
        Nil => ()
        _ => ()
      }
      let metadata = match metadata_val {
        Map(m) => {
          let map = {}
          for k, v in m {
            match v {
              String(vs) => map[k] = vs
              _ => ()
            }
          }
          Some(map)
        }
        _ => None
      }
      let latency_history = latency_history_val.map(fn(v) {
        match v {
          Int(i) => i
          _ => 0
        }
      })
      let last_ping_time = match last_ping_time_val {
        UInt64(t) => Some(t)
        _ => None
      }
      let session_id = match session_id_val {
        String(s) => Some(s)
        _ => None
      }
      Some(Connection::{
        peer_id,
        relay,
        latency_ms,
        bandwidth_mbps,
        packet_loss_rate,
        id,
        last_seen,
        quality,
        metadata,
        latency_history,
        packets_sent,
        packets_lost,
        bytes_sent,
        bytes_received,
        last_ping_time,
        version,
        nat_type,
        session_id,
      })
    }
    _ => None
  }
}
