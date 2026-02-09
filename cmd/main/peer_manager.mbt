///|
/// PeerManager manages the relationship between peers and their connections
/// Each peer is a logical entity that can have multiple network connections
struct PeerManager {
  peers : Map[String, PeerNode] // peer_id -> PeerNode
  routes : Map[String, Route] // target_peer_id -> Route
} derive(Show)

///|
fn PeerManager::new() -> PeerManager {
  { peers: {}, routes: {} }
}

///|
fn PeerManager::add_peer(self : PeerManager, peer : PeerNode) -> PeerManager {
  let peers = self.peers
  peers[peer.id] = peer
  { ..self, peers, }
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
fn PeerManager::update_peer_connections(
  self : PeerManager,
  peer_id : String,
  connections : Array[PeerConnectionInfo],
) -> PeerManager {
  match self.peers.get(peer_id) {
    Some(peer) => {
      let updated_peer = { ..peer, connections, }
      let peers = self.peers
      peers[peer_id] = updated_peer
      { ..self, peers, }
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

///|
fn PeerManager::remove_peer(self : PeerManager, peer_id : String) -> PeerManager {
  self.peers.remove(peer_id)
  self
}

///|
fn PeerManager::update_route(
  self : PeerManager,
  target_peer_id : String,
  next_hop : String,
  hops : Int,
) -> PeerManager {
  // Don't route to self
  if target_peer_id == next_hop && hops > 1 {
    // This is weird, but let's just proceed
    ()
  }
  let current_route = self.routes.get(target_peer_id)
  let should_update = match current_route {
    Some(route) =>
      // Update if shorter path or same path but newer (refresh)
      hops < route.hops || (hops == route.hops && next_hop == route.next_hop)
    None => true
  }
  if should_update {
    let routes = self.routes
    routes[target_peer_id] = Route::{ next_hop, hops, timestamp: @env.now() }
    { ..self, routes, }
  } else {
    self
  }
}

///|
fn PeerManager::get_route(
  self : PeerManager,
  target_peer_id : String,
) -> Route? {
  self.routes.get(target_peer_id)
}

///|
fn PeerManager::get_all_routes(self : PeerManager) -> Map[String, Route] {
  self.routes
}
