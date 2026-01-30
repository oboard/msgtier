///|
/// Connection represents a network connection to a peer
/// Each peer can have multiple connections (e.g., multiple network interfaces, redundant paths)
struct Connection {
  id : String
  local_addr : String
  remote_addr : String
  peer_id : String
  state : ConnectionState
  last_seen : Int64 // timestamp
  quality : Int // connection quality metric (0-100)
  metadata : Map[String, String]?
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
    last_seen: 0L,
    quality: 0,
    metadata: None,
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
///  // This function is used for connection health monitoring
fn Connection::update_last_seen(
  self : Connection,
  timestamp : Int64,
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

// ///|
// ///  // This function is used for connection serialization
// fn Connection::to_msgpack(self : Connection) -> @msgpack.Value {
//   let msg_map = {
//     "id": @msgpack.string(self.id),
//     "local_addr": @msgpack.string(self.local_addr),
//     "remote_addr": @msgpack.string(self.remote_addr),
//     "peer_id": @msgpack.string(self.peer_id),
//     "state": @msgpack.string(self.state.to_string()),
//     "last_seen": @msgpack.int64(self.last_seen),
//     "quality": @msgpack.int(self.quality),
//   }
//   match self.metadata {
//     Some(metadata) => {
//       let meta_map = {}
//       for k, v in metadata {
//         meta_map[k] = @msgpack.string(v)
//       }
//       msg_map["metadata"] = @msgpack.map(meta_map)
//     }
//     None => msg_map["metadata"] = @msgpack.nil()
//   }
//   @msgpack.map(msg_map)
// }

// ///|
// ///  // This function is used for connection deserialization
// fn Connection::from_msgpack(value : @msgpack.Value) -> Connection raise {
//   match value {
//     Map(msg_map) => {
//       let id = match msg_map["id"] {
//         String(s) => s
//         _ => raise @msgpack.InvalidData("missing connection id")
//       }
//       let local_addr = match msg_map["local_addr"] {
//         String(s) => s
//         _ => raise @msgpack.InvalidData("missing local_addr")
//       }
//       let remote_addr = match msg_map["remote_addr"] {
//         String(s) => s
//         _ => raise @msgpack.InvalidData("missing remote_addr")
//       }
//       let peer_id = match msg_map["peer_id"] {
//         String(s) => s
//         _ => raise @msgpack.InvalidData("missing peer_id")
//       }
//       let state = match msg_map["state"] {
//         String(s) =>
//           match s {
//             "Init" => Init
//             "Connecting" => Connecting
//             "Connected" => Connected
//             "Disconnected" => Disconnected
//             "Failed" => Failed
//             _ => raise @msgpack.InvalidData("invalid state")
//           }
//         _ => raise @msgpack.InvalidData("missing state")
//       }
//       let last_seen = match msg_map["last_seen"] {
//         Int64(i) => i
//         _ => 0L
//       }
//       let quality = match msg_map["quality"] {
//         Int(i) => i
//         _ => 0
//       }
//       let metadata = match msg_map["metadata"] {
//         Map(meta_map) => {
//           let metadata_map = {}
//           for k, v in meta_map {
//             match v {
//               String(s) => metadata_map[k] = s
//               _ => ()
//             }
//           }
//           Some(metadata_map)
//         }
//         _ => None
//       }
//       Connection::{
//         id,
//         local_addr,
//         remote_addr,
//         peer_id,
//         state,
//         last_seen,
//         quality,
//         metadata,
//       }
//     }
//     _ => raise @msgpack.InvalidData("invalid connection data")
//   }
// }

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
      new_ids.push(conn.id)
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
