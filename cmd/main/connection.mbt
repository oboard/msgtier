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
  latency_history : Array[Int] // Recent RTT samples (last 10)
  packets_sent : Int // Total pings sent
  packets_lost : Int // Pings without pong response
  bytes_sent : UInt64 // Total bytes sent through connection
  bytes_received : UInt64 // Total bytes received
  last_ping_time : UInt64? // Timestamp when last ping was sent
} derive(Show, ToJson, FromJson)

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
  peer_id : String,
  local_addr : String,
  remote_addr : String,
  protocol : String,
) -> Connection {
  {
    id: "\{peer_id}:\{local_addr}:\{remote_addr}",
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
  }
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
