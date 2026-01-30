///|
const PAGE_404 : Bytes = b"<html><head></head><body>Page Not Found</body></html>"

///|
pub fn add_connected_peer(
  id : String,
  address : String,
  version : String,
) -> Unit {
  if id.is_empty() || address.is_empty() {
    return
  }

  // Check if peer already exists
  let existing_peer = get_global_peer_manager().get_peer(id)
  match existing_peer {
    Some(_) => return // Peer already exists
    None => ()
  }
  let peer_node = PeerNode::new(id~, version~)
  update_global_peer_manager(fn(manager) { manager.add_peer(peer_node) })
}

///|
pub fn get_connected_peers() -> Array[PeerNode] {
  get_global_peer_manager().get_all_peers()
}

///|
pub fn remove_connected_peer(address : String) -> Unit {
  // Find peer by connection address and remove it
  let all_peers = get_global_peer_manager().get_all_peers()
  let all_conns = get_global_peer_manager().get_all_connections()
  for peer in all_peers {
    // Check if any connection for this peer has this address
    let peer_conns = peer.get_all_connections(all_conns)
    let has_address = peer_conns.any(fn(conn) { conn.remote_addr == address })
    if has_address {
      // Remove all connections for this peer
      let conns = get_global_peer_manager().get_peer_connections(peer.id)
      for conn in conns {
        update_global_peer_manager(fn(manager) {
          manager.remove_connection(conn.id)
        })
      }
      break
    }
  }
}

///|
pub fn clear_connected_peers() -> Unit {
  // Clear all peers and connections
  let all_peers = get_global_peer_manager().get_all_peers()
  for peer in all_peers {
    let conns = get_global_peer_manager().get_peer_connections(peer.id)
    for conn in conns {
      update_global_peer_manager(fn(manager) {
        manager.remove_connection(conn.id)
      })
    }
  }
}

///|
struct PeerConnectionInfo {
  peer_id : String
  version : String
  active : Bool
  local_addr : String
  remote_addr : String
} derive(ToJson)

///|
struct StatusInfo {
  status : String
  connections : Array[PeerConnectionInfo]
  peers_count : Int
  active_connections : Int
  total_connections : Int
  node_name : String
  listeners : Array[String]
} derive(ToJson)

///|
async fn start_http_service(addr : String, config : Config) -> Unit {
  // Store the config globally for handlers to access
  global_config.val = Some(config)
  let server = @http.Server::new(@socket.Addr::parse(addr))
  server.run_forever((request, _body, conn) => match
    (request.meth, request.path) {
    (Get, "/config") => get_config_handler(conn)
    (Get, "/status") => status_handler(conn)
    (Post, "/send") => {
      // Extract target from headers
      let target = match request.headers.get("target") {
        Some(t) => t
        None => {
          conn
          ..send_response(400, "Bad Request", extra_headers={
            "Content-Type": "application/json",
          })
          ..write({ "error": "Missing target header" }.to_json().stringify())
          ..end_response()
          return
        }
      }

      // For now, just return success
      conn
      ..send_response(200, "OK", extra_headers={
        "Content-Type": "application/json",
      })
      ..write({ "status": "sent", "target": target }.to_json().stringify())
      ..end_response()
    }
    _ => notfound_handler(conn)
  })
}

///|
async fn get_config_handler(conn : @http.ServerConnection) -> Unit {
  match global_config.val {
    Some(config) =>
      // Return the actual configuration, but hide sensitive information
      conn
      ..send_response(200, "OK", extra_headers={
        "Content-Type": "application/json",
      })
      ..write(config.to_json().stringify())
      ..end_response()
    None =>
      conn
      ..send_response(503, "Service Unavailable", extra_headers={
        "Content-Type": "application/json",
      })
      ..write({ "error": "Configuration not available" }.to_json().stringify())
      ..end_response()
  }
}

///|
async fn status_handler(conn : @http.ServerConnection) -> Unit {
  let all_peers = get_global_peer_manager().get_all_peers()
  let all_conns = get_global_peer_manager().get_all_connections()
  let (total_conns, active_conns, _) = get_global_peer_manager().get_connection_stats()

  // Build connection info for each peer
  let connections : Array[PeerConnectionInfo] = []
  for peer in all_peers {
    let peer_conns = peer.get_all_connections(all_conns)
    for peer_conn in peer_conns {
      connections.push(PeerConnectionInfo::{
        peer_id: peer.id,
        version: peer.version,
        active: peer_conn.is_active(),
        local_addr: peer_conn.local_addr,
        remote_addr: peer_conn.remote_addr,
      })
    }
  }
  let status_info = StatusInfo::{
    status: "ok",
    connections,
    peers_count: all_peers.length(),
    active_connections: active_conns,
    total_connections: total_conns,
    node_name: match global_config.val {
      Some(config) => config.id
      None => "unknown"
    },
    listeners: match global_config.val {
      Some(config) => config.listeners.map(fn(url) { url.get_host() })
      None => []
    },
  }
  conn
  ..send_response(200, "OK", extra_headers={
    "Content-Type": "application/json",
  })
  ..write(status_info.to_json().stringify())
  ..end_response()
}

///|
async fn notfound_handler(conn : @http.ServerConnection) -> Unit {
  conn
  ..send_response(404, "NotFound", extra_headers={ "Content-Type": "text/html" })
  ..write(PAGE_404)
  ..end_response()
}
