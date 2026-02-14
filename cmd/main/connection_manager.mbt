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
  let peer_connections = self.peer_connections
  match peer_connections.get(conn.peer_id) {
    Some(existing_ids) =>
      for id in existing_ids {
        if id != conn.id {
          connections.remove(id)
        }
      }
    None => ()
  }
  connections[conn.id] = conn
  peer_connections[conn.peer_id] = [conn.id]
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
fn ConnectionManager::get_all_connections(
  self : ConnectionManager,
) -> Array[Connection] {
  let conns = []
  for _, conn_ids in self.peer_connections {
    for id in conn_ids {
      match self.connections.get(id) {
        Some(conn) => conns.push(conn)
        None => ()
      }
    }
  }
  conns
}

///|
fn ConnectionManager::remove_connection(
  self : ConnectionManager,
  conn_id : String,
) -> ConnectionManager {
  let connections = self.connections
  match connections.get(conn_id) {
    Some(conn) => {
      connections.remove(conn_id)
      let peer_connections = self.peer_connections
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
      { connections, peer_connections }
    }
    None => self
  }
}

///|
fn ConnectionManager::update_connection_ports(
  self : ConnectionManager,
  conn_id : String,
  local_port : Int,
  protocol : Protocol,
  remote_port : Int,
  timestamp : UInt64,
) -> ConnectionManager {
  let connections = self.connections
  match connections.get(conn_id) {
    Some(conn) => {
      let updated_conn = conn.touch_port(
        local_port, protocol, remote_port, timestamp,
      )
      connections[conn_id] = updated_conn
      { connections, peer_connections: self.peer_connections }
    }
    None => self
  }
}

///|
fn ConnectionManager::prune_connection_ports(
  self : ConnectionManager,
  conn_id : String,
  now : UInt64,
  timeout_ms : UInt64,
) -> ConnectionManager {
  let connections = self.connections
  match connections.get(conn_id) {
    Some(conn) => {
      let updated_conn = conn.prune_ports(now, timeout_ms)
      connections[conn_id] = updated_conn
      { connections, peer_connections: self.peer_connections }
    }
    None => self
  }
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
fn ConnectionManager::update_connection_session_id(
  self : ConnectionManager,
  conn_id : String,
  session_id : String?,
) -> ConnectionManager {
  let connections = self.connections
  match connections.get(conn_id) {
    Some(conn) => {
      connections[conn_id] = conn.update_session_id(session_id)
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
      // Keep last 5 samples (approx. 15s at 3s interval)
      if history.length() > 5 {
        let start_idx = history.length() - 5
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

///|
fn ConnectionManager::update_connection_pong_time(
  self : ConnectionManager,
  conn_id : String,
  pong_time : UInt64?,
) -> ConnectionManager {
  let connections = self.connections
  match connections.get(conn_id) {
    Some(conn) => {
      let updated_conn = conn.update_last_pong_time(pong_time)
      connections[conn_id] = updated_conn
      { connections, peer_connections: self.peer_connections }
    }
    None => self
  }
}
