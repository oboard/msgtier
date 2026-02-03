///|
/// PeerNode represents a logical node in the P2P network
/// A peer is identified by its unique ID and may have multiple network connections
struct PeerNode {
  id : String
  version : String
  metadata : Map[String, String]?
  public_key : String? // Serialized RSA public key for E2E encryption
  addresses : Array[String] // All known addresses for this peer (from gossip discovery)
} derive(Show, ToJson, FromJson)

///|
/// PeerNodeStatus represents the aggregate status of a peer based on its connections
enum PeerNodeStatus {
  Unknown // No connection information
  Disconnected // No active connections
  Connected // Has at least one active connection
} derive(Show, ToJson, FromJson, Eq)

///|
/// PeerNodeWithStatus combines peer information with its current status
struct PeerNodeWithStatus {
  peer : PeerNode
  status : PeerNodeStatus
  active_connections : Int
  total_connections : Int
} derive(Show, ToJson, FromJson)

///|
fn PeerNode::new(
  id~ : String,
  version~ : String,
  public_key? : String,
  addresses? : Array[String] = [],
) -> PeerNode {
  { id, version, metadata: None, public_key, addresses }
}

// ///|
// fn PeerNode::get_status(
//   self : PeerNode,
//   connections : Array[Connection],
// ) -> PeerNodeStatus {
//   let active_conns = connections.filter(fn(conn) {
//     conn.peer_id == self.id && conn.is_active()
//   })
//   if active_conns.is_empty() {
//     Disconnected
//   } else {
//     Connected
//   }
// }

// ///|
// fn PeerNode::get_active_connections(
//   self : PeerNode,
//   connections : Array[Connection],
// ) -> Array[Connection] {
//   connections.filter(fn(conn) { conn.peer_id == self.id && conn.is_active() })
// }

///|
fn PeerNode::get_all_connections(
  self : PeerNode,
  connections : Array[Connection],
) -> Array[Connection] {
  connections.filter(fn(conn) { conn.peer_id == self.id })
}

///|
/// NetworkAddress represents a network endpoint (IP:port or hostname:port)
struct NetworkAddress {
  address : String
} derive(Show, ToJson, FromJson, Eq)

///|
/// NetworkDiscoveryInfo represents information exchanged during network discovery
struct NetworkDiscoveryInfo {
  id : String
  version : String
  addresses : Array[NetworkAddress] // Multiple network addresses for this peer
  peers : Array[NetworkAddress]? // Known peer addresses
  public_key : String? // RSA public key for E2E encryption
} derive(Show, ToJson, FromJson)

///|
/// Helper function to create a NetworkAddress
pub fn network_address(address : String) -> NetworkAddress {
  NetworkAddress::{ address, }
}

///|
/// Helper function to create NetworkDiscoveryInfo
pub fn network_discovery_info(
  id : String,
  version : String,
  addresses : Array[NetworkAddress],
  peers? : Array[NetworkAddress],
  public_key? : String,
) -> NetworkDiscoveryInfo {
  NetworkDiscoveryInfo::{ id, version, addresses, peers, public_key }
}
