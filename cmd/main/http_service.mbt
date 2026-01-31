///|
const PAGE_404 : Bytes = b"<html><head></head><body>Page Not Found</body></html>"

///|
fn format_latency(latency_ms : Int?) -> String {
  match latency_ms {
    Some(ms) => "\{ms} ms"
    None => "N/A"
  }
}

///|
fn format_bandwidth(mbps : Double) -> String {
  if mbps == 0.0 {
    "0 Mbps"
  } else if mbps < 0.0001 {
    "< 0.0001 Mbps"
  } else {
    // Round to 4 decimal places
    let multiplier = 10000.0
    let rounded = ((mbps * multiplier).to_int().to_double()) / multiplier
    "\{rounded} Mbps"
  }
}

///|
fn format_packet_loss(rate : Int) -> String {
  if rate == 0 {
    "0%"
  } else {
    "\{rate}%"
  }
}

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
  relay : Int
  local_addr : String
  remote_addr : String
  latency_ms : Int?
  latency_display : String
  bandwidth_mbps : Double
  bandwidth_display : String
  packet_loss_rate : Int
  packet_loss_display : String
} derive(ToJson)

///|
struct StatusInfo {
  status : String
  peers : Array[PeerNode]
  connections : Array[PeerConnectionInfo]
  peers_count : Int
  node_id : String
  listeners : Array[String]
} derive(ToJson)

///|
async fn start_http_service(addr : String, config : Config) -> Unit {
  // Store the config globally for handlers to access
  global_config.val = Some(config)
  let server = @http.Server::new(@socket.Addr::parse(addr))
  server.run_forever((request, body, conn) => match
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

      // Read request body (convert from Bytes to String)
      let body_str = body.read_all().text()

      // Get current node ID and local address
      let node_id = match global_config.val {
        Some(config) => config.id
        None => "unknown"
      }
      let local_addr = match global_config.val {
        Some(config) => {
          let addrs = config.listeners.map(fn(url) { url.get_host() })
          if addrs.is_empty() {
            "127.0.0.1:0"
          } else {
            addrs[0]
          }
        }
        None => "127.0.0.1:0"
      }

      // Create data message to send with body as data
      let msg = Message::new(
        kind="data",
        from=node_id,
        addr=local_addr,
        version=Some(VERSION),
        target=Some(target),
        data=Some(body_str),
      )

      // Add to pending message queue
      add_pending_message(target, msg)

      // Check if target peer exists or is self
      let target_peer = get_global_peer_manager().get_peer(target)
      let is_self = target == node_id
      match (target_peer, is_self) {
        (Some(_), _) | (None, true) =>
          conn
          ..send_response(200, "OK", extra_headers={
            "Content-Type": "application/json",
          })
          ..write(
            { "status": "queued", "target": target, "data": body_str }
            .to_json()
            .stringify(),
          )
          ..end_response()
        (None, false) =>
          conn
          ..send_response(404, "Not Found", extra_headers={
            "Content-Type": "application/json",
          })
          ..write(
            { "error": "Target peer not found", "target": target }
            .to_json()
            .stringify(),
          )
          ..end_response()
      }
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

  // Build connection info for each peer
  let connections : Array[PeerConnectionInfo] = []
  for peer in all_peers {
    let peer_conns = peer.get_all_connections(all_conns)
    for peer_conn in peer_conns {
      // Calculate metrics
      let latency_ms = peer_conn.latency_ms
      let latency_display = format_latency(latency_ms)
      let elapsed_ms = @env.now() - peer_conn.last_seen
      let bandwidth_mbps = peer_conn.calculate_bandwidth_mbps(elapsed_ms)
      let bandwidth_display = format_bandwidth(bandwidth_mbps)
      let packet_loss_rate = peer_conn.calculate_packet_loss()
      let packet_loss_display = format_packet_loss(packet_loss_rate)
      connections.push(PeerConnectionInfo::{
        peer_id: peer.id,
        version: peer.version,
        active: peer_conn.is_active(),
        relay: peer_conn.relay,
        local_addr: peer_conn.local_addr,
        remote_addr: peer_conn.remote_addr,
        latency_ms,
        latency_display,
        bandwidth_mbps,
        bandwidth_display,
        packet_loss_rate,
        packet_loss_display,
      })
    }
  }
  let status_info = StatusInfo::{
    status: "ok",
    peers: all_peers,
    connections,
    peers_count: all_peers.length(),
    node_id: match global_config.val {
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
