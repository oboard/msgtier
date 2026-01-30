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
fn PeerManager::get_connection_stats(self : PeerManager) -> (Int, Int, Int) {
  let all_conns = self.connection_manager.get_all_connections()
  let total = all_conns.length()
  let active = all_conns.filter(fn(conn) { conn.is_active() }).length()
  let peers = self.peers.length()
  (total, active, peers)
}

///|
fn PeerManager::get_all_connections(self : PeerManager) -> Array[Connection] {
  self.connection_manager.get_all_connections()
}

///|
fn PeerManager::remove_connection(
  self : PeerManager,
  conn_id : String,
) -> PeerManager {
  let updated_manager = self.connection_manager.remove_connection(conn_id)
  { ..self, connection_manager: updated_manager }
}
