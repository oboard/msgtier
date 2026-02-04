///|
const PAGE_404 : Bytes = b"<html><head></head><body>Page Not Found</body></html>"

///|
pub fn get_connected_peers() -> Array[PeerNode] {
  get_global_peer_manager().get_all_peers()
}

///|
pub fn remove_connected_peer(address : String) -> Unit {
  // Find peer by connection address and remove it
  let all_peers = get_global_peer_manager().get_all_peers()
  let all_conns = get_global_connection_manager().get_all_connections()
  for peer in all_peers {
    // Check if any connection for this peer has this address
    let peer_conns = peer.get_all_connections(all_conns)
    let has_address = peer_conns.any(fn(conn) { conn.remote_addr == address })
    if has_address {
      // Remove all connections for this peer
      let conns = get_global_connection_manager().get_peer_connections(peer.id)
      for conn in conns {
        update_global_connection_manager(fn(manager) {
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
    let conns = get_global_connection_manager().get_peer_connections(peer.id)
    for conn in conns {
      update_global_connection_manager(fn(manager) {
        manager.remove_connection(conn.id)
      })
    }
  }
}

///|

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
      let config = get_config()
      // Get current node ID and local address
      let peer_id = config.id
      let addrs = config.listeners.map(fn(url) { url.get_host() })
      let local_addr = if addrs.is_empty() { "127.0.0.1:0" } else { addrs[0] }

      // Create data message to send with body as data
      let msg = Message::new(
        kind="data",
        from=peer_id,
        addr=local_addr,
        relay=1,
        version=VERSION,
        target~,
        data=@msgpack.binary(
          encrypt_for_peer(peer_id, @msgpack.encode(@msgpack.string(body_str))),
        ),
      )

      // Print to stdout for debugging
      println("HTTP /send: Queuing message to \{target}")
      println("  From: \{peer_id}")
      println("  Local: \{local_addr}")
      println("  Data: \{body_str}")

      // Add to pending message queue
      add_pending_message(target, msg)

      // Check if target peer exists or is self
      let target_peer = get_global_peer_manager().get_peer(target)
      let is_self = target == peer_id
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
fn get_config() -> Config {
  match global_config.val {
    Some(config) => config
    None => abort("Missing config")
  }
}

///|
async fn status_handler(conn : @http.ServerConnection) -> Unit {
  let all_peers = get_global_peer_manager().get_all_peers()

  // Add myself to the peers list to show my connections
  let my_config = get_config()
  let my_id = my_config.id
  let my_pk = get_public_key()
  let my_addrs = my_config.listeners.map(fn(url) { url.get_host() })

  // Get my active direct connections
  let all_conns = get_global_connection_manager().get_all_connections()
  let my_connections : Array[PeerConnectionInfo] = []
  for conn in all_conns {
    if conn.state == ConnectionState::Connected && conn.relay == 1 {
      let elapsed_ms = @env.now() - conn.last_seen
      let bandwidth_mbps = conn.calculate_bandwidth_mbps(elapsed_ms)
      let packet_loss_rate = conn.calculate_packet_loss()
      my_connections.push(PeerConnectionInfo::{
        peer_id: conn.peer_id,
        latency_ms: conn.latency_ms,
        bandwidth_mbps,
        packet_loss_rate,
        id: conn.id,
        local_addr: conn.local_addr,
        remote_addr: conn.remote_addr,
        state: conn.state,
        last_seen: conn.last_seen,
        quality: conn.quality,
        relay: conn.relay,
        metadata: conn.metadata,
        latency_history: conn.latency_history,
        packets_sent: conn.packets_sent,
        packets_lost: conn.packets_lost,
        bytes_sent: conn.bytes_sent,
        bytes_received: conn.bytes_received,
        last_ping_time: conn.last_ping_time,
      })
    }
  }
  let me = PeerNode::new(
    id=my_id,
    version=VERSION,
    public_key=my_pk,
    addresses=my_addrs,
    metadata=my_config.metadata.unwrap_or({}),
  )
  let me_with_conns = { ..me, connections: my_connections }
  all_peers.push(me_with_conns)

  // Include routing table info
  let all_routes = get_global_peer_manager().get_all_routes()
  let routes_info : Array[RouteInfo] = []
  for target_id, route in all_routes {
    routes_info.push(RouteInfo::{
      target_peer_id: target_id,
      next_hop: route.next_hop,
      hops: route.hops,
      timestamp: route.timestamp,
    })
  }

  // Build known peers list (from active discovery)
  let known_peers = get_all_known_peers()
  let config = get_config()
  let status_info = StatusInfo::{
    status: "ok",
    peers: all_peers,
    peers_count: all_peers.length(),
    peer_id: config.id,
    listeners: config.listeners.map(url => url.get_host()),
    known_peers,
    routes: routes_info,
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
