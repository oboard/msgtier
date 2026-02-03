///|
/// Connection represents a network connection to a peer
/// Each peer can have multiple connections (e.g., multiple network interfaces, redundant paths)
struct Connection {
  id : String
  local_addr : String
  remote_addr : String
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
) -> Connection {
  {
    id: "\{peer_id}:\{local_addr}:\{remote_addr}",
    local_addr,
    remote_addr,
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
fn Connection::update_last_ping_time(self : Connection, time : UInt64?) -> Connection {
  { ..self, last_ping_time: time }
}

///|
/// Connection manager to handle multiple connections per peer
struct ConnectionManager {
  connections : Map[String, Connection] // connection_id -> Connection
  peer_connections : Map[String, Array[String]] // peer_id -> connection_ids
} derive(Show)

///|
fn ConnectionManager::new() -> ConnectionManager {
  { connections: {}, peer_connections: {} }
}

///|
fn ConnectionManager::add_connection(
  self : ConnectionManager,
  conn : Connection,
) -> ConnectionManager {
  let connections = self.connections
  connections[conn.id] = conn
  let peer_connections = self.peer_connections
  let peer_conns = match peer_connections.get(conn.peer_id) {
    Some(ids) => {
      let new_ids = ids.copy()
      // Only add if not already present
      if !new_ids.any(fn(id) { id == conn.id }) {
        new_ids.push(conn.id)
      }
      new_ids
    }
    None => [conn.id]
  }
  peer_connections[conn.peer_id] = peer_conns
  { connections, peer_connections }
}

///|
fn ConnectionManager::remove_connection(
  self : ConnectionManager,
  conn_id : String,
) -> ConnectionManager {
  let connections = self.connections
  let peer_connections = self.peer_connections
  match connections.get(conn_id) {
    Some(conn) => {
      connections.remove(conn_id)
      match peer_connections.get(conn.peer_id) {
        Some(ids) => {
          let new_ids = ids.filter(fn(id) { id != conn_id })
          if new_ids.is_empty() {
            peer_connections.remove(conn.peer_id)
          } else {
            peer_connections[conn.peer_id] = new_ids
          }
        }
        None => ()
      }
    }
    None => ()
  }
  { connections, peer_connections }
}

///|
fn ConnectionManager::get_peer_connections(
  self : ConnectionManager,
  peer_id : String,
) -> Array[Connection] {
  match self.peer_connections.get(peer_id) {
    Some(conn_ids) => {
      let conns = []
      for id in conn_ids {
        match self.connections.get(id) {
          Some(conn) => conns.push(conn)
          None => ()
        }
      }
      conns
    }
    None => []
  }
}

///|
fn ConnectionManager::get_active_connections(
  self : ConnectionManager,
  peer_id : String,
) -> Array[Connection] {
  self.get_peer_connections(peer_id).filter(fn(conn) { conn.is_active() })
}

///|
fn ConnectionManager::get_all_connections(
  self : ConnectionManager,
) -> Array[Connection] {
  let conns = []
  for _, conn in self.connections {
    conns.push(conn)
  }
  conns
}

///|
fn ConnectionManager::update_connection_relay(
  self : ConnectionManager,
  conn_id : String,
  relay_depth : Int,
) -> ConnectionManager {
  let connections = self.connections
  match connections.get(conn_id) {
    Some(conn) => {
      connections[conn_id] = conn.update_relay(relay_depth)
      { connections, peer_connections: self.peer_connections }
    }
    None => self
  }
}

///|
fn ConnectionManager::get_best_direct_connection(
  self : ConnectionManager,
  peer_id : String,
) -> Connection? {
  let active_conns = self.get_active_connections(peer_id)
  if active_conns.is_empty() {
    None
  } else {
    // Prefer direct connections (relay = 1)
    let direct = active_conns.filter(fn(c) { c.relay == 1 })
    if !direct.is_empty() {
      Some(direct[0])
    } else {
      // Fallback to any active connection, preferring lower relay depth
      Some(
        active_conns.fold(init=active_conns[0], fn(best, conn) {
          if conn.relay < best.relay {
            conn
          } else {
            best
          }
        }),
      )
    }
  }
}

///|
fn ConnectionManager::update_connection_state(
  self : ConnectionManager,
  conn_id : String,
  state : ConnectionState,
) -> ConnectionManager {
  let connections = self.connections
  match connections.get(conn_id) {
    Some(conn) => {
      connections[conn_id] = conn.update_state(state)
      { connections, peer_connections: self.peer_connections }
    }
    None => self
  }
}

///|
fn ConnectionManager::update_connection_last_seen(
  self : ConnectionManager,
  conn_id : String,
  timestamp : UInt64,
) -> ConnectionManager {
  let connections = self.connections
  match connections.get(conn_id) {
    Some(conn) => {
      connections[conn_id] = conn.update_last_seen(timestamp)
      { connections, peer_connections: self.peer_connections }
    }
    None => self
  }
}

///|
fn ConnectionManager::update_connection_latency(
  self : ConnectionManager,
  conn_id : String,
  rtt_ms : Int,
) -> ConnectionManager {
  let connections = self.connections
  match connections.get(conn_id) {
    Some(conn) => {
      let mut history = conn.latency_history.copy()
      history.push(rtt_ms)
      if history.length() > 10 {
        let start_idx = history.length() - 10
        let new_history = []
        for i in start_idx..<history.length() {
          new_history.push(history[i])
        }
        history = new_history
      }
      let updated_conn = {
        ..conn,
        latency_ms: Some(rtt_ms),
        latency_history: history,
      }
      connections[conn_id] = updated_conn
      { connections, peer_connections: self.peer_connections }
    }
    None => self
  }
}

///|
fn ConnectionManager::update_connection_bytes(
  self : ConnectionManager,
  conn_id : String,
  bytes_sent : UInt64,
  bytes_received : UInt64,
) -> ConnectionManager {
  let connections = self.connections
  match connections.get(conn_id) {
    Some(conn) => {
      let updated_conn = {
        ..conn,
        bytes_sent: conn.bytes_sent + bytes_sent,
        bytes_received: conn.bytes_received + bytes_received,
      }
      connections[conn_id] = updated_conn
      { connections, peer_connections: self.peer_connections }
    }
    None => self
  }
}

///|
fn ConnectionManager::update_connection_packet_loss(
  self : ConnectionManager,
  conn_id : String,
  packets_sent : Int,
  packets_lost : Int,
) -> ConnectionManager {
  let connections = self.connections
  match connections.get(conn_id) {
    Some(conn) => {
      let updated_conn = {
        ..conn,
        packets_sent: conn.packets_sent + packets_sent,
        packets_lost: conn.packets_lost + packets_lost,
      }
      connections[conn_id] = updated_conn
      { connections, peer_connections: self.peer_connections }
    }
    None => self
  }
}

///|
fn ConnectionManager::update_connection_ping_time(
  self : ConnectionManager,
  conn_id : String,
  ping_time : UInt64?,
) -> ConnectionManager {
  let connections = self.connections
  match connections.get(conn_id) {
    Some(conn) => {
      let updated_conn = conn.update_last_ping_time(ping_time)
      connections[conn_id] = updated_conn
      { connections, peer_connections: self.peer_connections }
    }
    None => self
  }
}
