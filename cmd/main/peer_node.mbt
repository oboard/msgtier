///|
/// PeerNode represents a logical node in the P2P network
/// A peer is identified by its unique ID and may have multiple network connections
struct PeerNode {
  id : String
  version : String
  metadata : Map[String, String]
  addresses : Array[String] // All known addresses for this peer (from gossip discovery)
  connections : Array[PeerConnectionInfo] // List of peer IDs this peer is connected to
} derive(Show)

///|
impl ToJson for PeerNode with to_json(self) {
  {
    "id": self.id,
    "version": self.version,
    "metadata": self.metadata,
    "addresses": self.addresses,
    "connections": self.connections,
  }
}

///|
/// PeerNodeStatus represents the aggregate status of a peer based on its connections
enum PeerNodeStatus {
  Unknown // No connection information
  Disconnected // No active connections
  Connected // Has at least one active connection
} derive(Show, ToJson, FromJson, Eq)

///|
fn PeerNode::new(
  id~ : String,
  version~ : String,
  addresses~ : Array[String],
  metadata~ : Map[String, String],
) -> PeerNode {
  { id, version, metadata, addresses, connections: [] }
}

// ///|
// fn PeerNode::get_all_connections(
//   self : PeerNode,
//   connections : Array[Connection],
// ) -> Array[Connection] {
//   connections.filter(fn(conn) { conn.peer_id == self.id })
// }
