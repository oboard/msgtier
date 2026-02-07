///|
/// Connection represents a network connection to a peer
/// Each peer can have multiple connections (e.g., multiple network interfaces, redundant paths)
struct Connection {
  id : String
  local_addr : String
  remote_addr : String
  protocol : String // "tcp", "udp", etc.
  peer_id : String
  state : ConnectionState
  last_seen : UInt64 // timestamp
  quality : Int // connection quality metric (0-100)
  relay : Int // 1 = direct, 2+ = relayed through N-1 peers
  metadata : Map[String, String]?
  latency_ms : Int? // Latest RTT in milliseconds (null if no pings yet)
  latency_history : Array[Int] // Recent RTT samples (last 20, approx 1 minute)
  packets_sent : Int // Total pings sent
  packets_lost : Int // Pings without pong response
  bytes_sent : UInt64 // Total bytes sent through connection
  bytes_received : UInt64 // Total bytes received
  last_ping_time : UInt64? // Timestamp when last ping was sent
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
enum ConnectionState {
  Init
  Connecting
  Connected
  Disconnected
  Failed
} derive(Show, ToJson, FromJson, Eq)

///|
fn Connection::new(
  my_id : String,
  peer_id : String,
  local_addr : String,
  remote_addr : String,
  protocol : String,
  session_id? : String,
) -> Connection {
  let (id1, id2) = if my_id < peer_id {
    (my_id, peer_id)
  } else {
    (peer_id, my_id)
  }

  // Use protocol and sorted peer IDs for ID to ensure consistency across peers
  // Ports are excluded to handle NAT where external ports may differ from internal ports
  // If session_id is provided, include it in the hash to distinguish multiple connections
  let raw_id = match session_id {
    Some(sid) => "\{id1}:\{id2}:\{protocol}:\{sid}"
    None => "\{id1}:\{id2}:\{protocol}"
  }
  let id = bytes_to_hex(Bytes::from_array(@crypto.sha256(@utf8.encode(raw_id))))

  // Analyze NAT type based on address characteristics
  // This is a preliminary analysis; accurate determination requires STUN/discovery
  let nat_type = analyze_nat_type(local_addr, remote_addr)
  {
    id,
    local_addr,
    remote_addr,
    protocol,
    peer_id,
    state: Init,
    last_seen: @env.now(),
    quality: 0,
    relay: 1,
    metadata: None,
    latency_ms: None,
    latency_history: [],
    packets_sent: 0,
    packets_lost: 0,
    bytes_sent: 0UL,
    bytes_received: 0UL,
    last_ping_time: None,
    nat_type,
    session_id,
  }
}

///|
fn analyze_nat_type(local_addr : String, remote_addr : String) -> NatType {
  // Simple heuristic analysis
  if local_addr.has_prefix("127.0.0.1") || local_addr.has_prefix("::1") {
    if remote_addr.has_prefix("127.0.0.1") || remote_addr.has_prefix("::1") {
      return NoNAT
    }
  }

  // If local is private and remote is public, likely behind some NAT
  // We default to Unknown as we can't distinguish Cone vs Symmetric without more tests
  Unknown
}

///|
fn Connection::update_state(
  self : Connection,
  new_state : ConnectionState,
) -> Connection {
  { ..self, state: new_state }
}

///|
fn Connection::update_relay(self : Connection, relay_depth : Int) -> Connection {
  { ..self, relay: relay_depth }
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
fn Connection::is_active(self : Connection) -> Bool {
  match self.state {
    Connected => true
    _ => false
  }
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
