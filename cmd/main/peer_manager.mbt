///|
/// PeerManager manages the relationship between peers and their connections
/// Each peer is a logical entity that can have multiple network connections
struct PeerManager {
  peers : Map[String, PeerNode] // peer_id -> PeerNode
  connection_manager : ConnectionManager
} derive(Show)

///|
fn PeerManager::new() -> PeerManager {
  { peers: {}, connection_manager: ConnectionManager::new() }
}

///|
fn PeerManager::add_peer(self : PeerManager, peer : PeerNode) -> PeerManager {
  let peers = self.peers
  peers[peer.id] = peer
  { ..self, peers, }
}

///|
fn PeerManager::update_peer_public_key(
  self : PeerManager,
  peer_id : String,
  public_key : String,
) -> PeerManager {
  match self.peers.get(peer_id) {
    Some(peer) => {
      let updated_peer = { ..peer, public_key: Some(public_key) }
      let peers = self.peers
      peers[peer_id] = updated_peer
      { ..self, peers, }
    }
    None => self
  }
}

///|
fn PeerManager::add_peer_address(
  self : PeerManager,
  peer_id : String,
  address : String,
) -> PeerManager {
  match self.peers.get(peer_id) {
    Some(peer) =>
      // Only add if not already present
      if !peer.addresses.contains(address) {
        let updated_addrs = peer.addresses
        updated_addrs.push(address)
        let updated_peer = { ..peer, addresses: updated_addrs }
        let peers = self.peers
        peers[peer_id] = updated_peer
        { ..self, peers, }
      } else {
        self
      }
    None => self
  }
}

///|
fn PeerManager::get_peer(self : PeerManager, peer_id : String) -> PeerNode? {
  self.peers.get(peer_id)
}

///|
fn PeerManager::get_all_peers(self : PeerManager) -> Array[PeerNode] {
  let peer_list = []
  for _, peer in self.peers {
    peer_list.push(peer)
  }
  peer_list
}

// ///|
// fn PeerManager::get_peers_with_status(
//   self : PeerManager,
// ) -> Array[PeerNodeWithStatus] {
//   let all_connections = self.connection_manager.get_all_connections()
//   let result = []
//   for _, peer in self.peers {
//     let status = peer.get_status(all_connections)
//     let active_conns = peer.get_active_connections(all_connections).length()
//     let total_conns = peer.get_all_connections(all_connections).length()
//     result.push(PeerNodeWithStatus::{
//       peer,
//       status,
//       active_connections: active_conns,
//       total_connections: total_conns,
//     })
//   }
//   result
// }

///|
fn PeerManager::add_connection(
  self : PeerManager,
  peer_id : String,
  local_addr : String,
  remote_addr : String,
) -> PeerManager {
  // First ensure the peer exists, if not create a basic one
  let peers = self.peers
  match self.peers.get(peer_id) {
    Some(_) => ()
    None => {
      let new_peer = PeerNode::new(id=peer_id, version=VERSION)
      peers[peer_id] = new_peer
    }
  }

  // Create new connection
  let conn = Connection::new(peer_id, local_addr, remote_addr)
  let updated_manager = self.connection_manager.add_connection(conn)
  { peers, connection_manager: updated_manager }
}

///|
fn PeerManager::get_peer_connections(
  self : PeerManager,
  peer_id : String,
) -> Array[Connection] {
  self.connection_manager.get_peer_connections(peer_id)
}

///|
fn PeerManager::get_active_peer_connections(
  self : PeerManager,
  peer_id : String,
) -> Array[Connection] {
  self.connection_manager.get_active_connections(peer_id)
}

///|
fn PeerManager::update_connection_state(
  self : PeerManager,
  conn_id : String,
  state : ConnectionState,
) -> PeerManager {
  match self.connection_manager.connections.get(conn_id) {
    Some(conn) => {
      let updated_conn = conn.update_state(state)
      let updated_manager = {
        ..self.connection_manager,
        connections: self.connection_manager.connections,
      }
      updated_manager.connections[conn_id] = updated_conn
      { ..self, connection_manager: updated_manager }
    }
    None => self
  }
}

///|
fn PeerManager::update_connection_last_seen(
  self : PeerManager,
  conn_id : String,
  timestamp : UInt64,
) -> PeerManager {
  match self.connection_manager.connections.get(conn_id) {
    Some(conn) => {
      let updated_conn = conn.update_last_seen(timestamp)
      let updated_manager = {
        ..self.connection_manager,
        connections: self.connection_manager.connections,
      }
      updated_manager.connections[conn_id] = updated_conn
      { ..self, connection_manager: updated_manager }
    }
    None => self
  }
}

///|
fn PeerManager::get_all_connections(self : PeerManager) -> Array[Connection] {
  self.connection_manager.get_all_connections()
}

///|
// /// Check if there is any active connection to a specific remote address
// fn PeerManager::has_active_connection_to_addr(
//   self : PeerManager,
//   addr : String,
// ) -> Bool {
//   let all_conns = self.connection_manager.get_all_connections()
//   for conn in all_conns {
//     if conn.remote_addr == addr && conn.state == Connected {
//       return true
//     }
//   }
//   false
// }

///|
fn PeerManager::remove_connection(
  self : PeerManager,
  conn_id : String,
) -> PeerManager {
  let updated_manager = self.connection_manager.remove_connection(conn_id)
  { ..self, connection_manager: updated_manager }
}

///|
fn PeerManager::update_connection_relay(
  self : PeerManager,
  conn_id : String,
  relay_depth : Int,
) -> PeerManager {
  let updated_manager = self.connection_manager.update_connection_relay(
    conn_id, relay_depth,
  )
  { ..self, connection_manager: updated_manager }
}

///|
fn PeerManager::update_connection_latency(
  self : PeerManager,
  conn_id : String,
  rtt_ms : Int,
) -> PeerManager {
  match self.connection_manager.connections.get(conn_id) {
    Some(conn) => {
      let mut history = conn.latency_history.copy()
      history.push(rtt_ms)
      // Keep only last 10 samples
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
      let updated_manager = {
        ..self.connection_manager,
        connections: self.connection_manager.connections,
      }
      updated_manager.connections[conn_id] = updated_conn
      { ..self, connection_manager: updated_manager }
    }
    None => self
  }
}

///|
fn PeerManager::update_connection_bytes(
  self : PeerManager,
  conn_id : String,
  bytes_sent : UInt64,
  bytes_received : UInt64,
) -> PeerManager {
  match self.connection_manager.connections.get(conn_id) {
    Some(conn) => {
      let updated_conn = {
        ..conn,
        bytes_sent: conn.bytes_sent + bytes_sent,
        bytes_received: conn.bytes_received + bytes_received,
      }
      let updated_manager = {
        ..self.connection_manager,
        connections: self.connection_manager.connections,
      }
      updated_manager.connections[conn_id] = updated_conn
      { ..self, connection_manager: updated_manager }
    }
    None => self
  }
}

///|
fn PeerManager::update_connection_packet_loss(
  self : PeerManager,
  conn_id : String,
  packets_sent : Int,
  packets_lost : Int,
) -> PeerManager {
  match self.connection_manager.connections.get(conn_id) {
    Some(conn) => {
      let updated_conn = {
        ..conn,
        packets_sent: conn.packets_sent + packets_sent,
        packets_lost: conn.packets_lost + packets_lost,
      }
      let updated_manager = {
        ..self.connection_manager,
        connections: self.connection_manager.connections,
      }
      updated_manager.connections[conn_id] = updated_conn
      { ..self, connection_manager: updated_manager }
    }
    None => self
  }
}

///|
fn PeerManager::update_connection_ping_time(
  self : PeerManager,
  conn_id : String,
  ping_time : UInt64?,
) -> PeerManager {
  match self.connection_manager.connections.get(conn_id) {
    Some(conn) => {
      let updated_conn = { ..conn, last_ping_time: ping_time }
      let updated_manager = {
        ..self.connection_manager,
        connections: self.connection_manager.connections,
      }
      updated_manager.connections[conn_id] = updated_conn
      { ..self, connection_manager: updated_manager }
    }
    None => self
  }
}
