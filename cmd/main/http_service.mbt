///|
const PAGE_404 : Bytes = b"<html><head></head><body>Page Not Found</body></html>"

///|
async fn handle_http_request(
  request : @http.Request,
  body : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  match (request.meth, request.path) {
    (Get, "/api/config") => get_config_handler(conn)
    (Get, "/api/status") => status_handler(conn)
    (Get, "/api/download") => download_handler(conn)
    (Post, "/api/send") => {
      // Extract target from headers
      let target_id = match request.headers.get("target") {
        Some(t) => t
        None => {
          conn
          ..send_response(400, "Bad Request", extra_headers={
            "Content-Type": "application/json",
          })
          ..write({ "error": "Missing target header" }.to_json().stringify())
          .end_response()
          return
        }
      }

      // Extract timeout from headers (default 10000ms)
      let timeout_ms = match request.headers.get("timeout") {
        Some(t) => @strconv.parse_uint64(t) catch { _ => 10000UL }
        None => 10000UL
      }

      // Read request body (convert from Bytes to String)
      let body_str = body.read_all().text()
      let config = get_config()
      // Get current node ID and local address
      let my_id = config.id
      let addrs = config.listeners
      let local_addr = if addrs.is_empty() { "127.0.0.1:0" } else { addrs[0] }

      // Prepare data payload (plain string for self, encrypted binary for others)
      let is_self = target_id.trim() == my_id
      let (data_val, is_encrypted) = if is_self {
        log_debug(
          "HTTP /send: Self-message detected, sending unencrypted binary",
        )
        (@msgpack.string(body_str), false)
      } else {
        // Encrypt for target peer
        let data = encrypt_for_peer(
          target_id,
          @msgpack.encode(@msgpack.string(body_str)),
        )
        if data.length() > 0 {
          (@msgpack.binary(data), true)
        } else {
          log_warn("No shared secret for \{target_id}, sending unencrypted")
          (@msgpack.string(body_str), false)
        }
      }

      // Create data message to send with body as data
      let msg = Message::new(
        kind="data",
        source_id=my_id,
        relay=1,
        version=VERSION,
        target_id~,
        body=data_val,
        encrypted=is_encrypted,
        timeout_ms~,
      )

      // Print to stdout for debugging
      log_debug("HTTP /send: Queuing message id=\{msg.id} to \{target_id}")
      log_debug("  From: \{my_id}")
      log_debug("  Local: \{local_addr}")
      log_debug("  Data: \{body_str}")
      log_debug("  Self: \{is_self}")
      log_debug("  Encrypted: \{is_encrypted}")
      log_debug("  Timeout: \{timeout_ms}ms")
      match data_val {
        Binary(b) => log_debug("  DataVal: Binary len=\{b.length()}")
        String(s) => log_debug("  DataVal: String len=\{s.length()}")
        _ => log_debug("  DataVal: Other")
      }
      log_info(
        "HTTP /send: Added pending message id=\{msg.id} target=\{target_id}",
      )

      // Check if target peer exists or is self
      let target_peer = get_global_peer_manager().get_peer(target_id)
      let is_self = target_id == my_id
      match (target_peer, is_self) {
        (Some(_), _) | (None, true) => {

          // Register request to track response
          add_pending_request(msg.id)

          // Add to pending message queue
          add_pending_message(msg)
          log_debug("HTTP /send: Registered request id=\{msg.id}")

          // Wait for response with timeout
          match wait_for_response(msg.id, timeout_ms.to_int()) {
            Some((response, headers)) =>
              // Ensure Content-Type is set if missing
              conn
              ..send_response(200, "OK", extra_headers=headers)
              ..write(response)
              .end_response()
            None =>
              conn
              ..send_response(504, "Gateway Timeout", extra_headers={
                "Content-Type": "application/json",
              })
              ..write(
                { "error": "Request timed out", "target": target_id }
                .to_json()
                .stringify(),
              )
              .end_response()
          }
        }
        (None, false) =>
          conn
          ..send_response(404, "Not Found", extra_headers={
            "Content-Type": "application/json",
          })
          ..write(
            { "error": "Target peer not found", "target": target_id }
            .to_json()
            .stringify(),
          )
          .end_response()
      }
    }
    (Get, path) => serve_static_handler(conn, path)
    _ => notfound_handler(conn)
  }
}

///|
async fn start_http_service(addr : String, config : Config) -> Unit {
  // Store the config globally for handlers to access
  global_config.val = Some(config)
  for {
    try {
      let server = @http.Server::new(@socket.Addr::parse(addr), reuse_addr=true)
      server.run_forever(handle_http_request)
    } catch {
      e => {
        log_warn("HTTP server failed to start: \{e}. Retrying in 5 seconds...")
        @async.sleep(5000)
      }
    }
  }
}

///|
async fn serve_static_handler(
  conn : @http.ServerConnection,
  path : String,
) -> Unit {
  let static_root = "web/dist"
  let path = if path == "/" { "/index.html" } else { path }

  // Basic security check
  if path.contains("..") {
    notfound_handler(conn)
    return
  }
  let full_path = static_root + path
  if @fs.exists(full_path) {
    serve_file(conn, full_path, path)
  } else {
    notfound_handler(conn)
  }
}

///|
async fn serve_file(
  conn : @http.ServerConnection,
  file_path : String,
  path : String,
) -> Unit {
  let file = @fs.open(file_path, mode=ReadOnly) catch {
    _ => {
      notfound_handler(conn)
      return
    }
  }
  defer file.close()
  try {
    let content_type = match path {
      _ as p if p.has_suffix(".html") => "text/html"
      _ as p if p.has_suffix(".css") => "text/css"
      _ as p if p.has_suffix(".js") => "text/javascript"
      _ as p if p.has_suffix(".json") => "application/json"
      _ as p if p.has_suffix(".png") => "image/png"
      _ as p if p.has_suffix(".jpg") || p.has_suffix(".jpeg") => "image/jpeg"
      _ as p if p.has_suffix(".svg") => "image/svg+xml"
      _ as p if p.has_suffix(".ico") => "image/x-icon"
      _ => "application/octet-stream"
    }
    conn
    ..send_response(200, "OK", extra_headers={ "Content-Type": content_type })
    ..write_reader(file)
    .end_response()
  } catch {
    _ => ()
  }
}

///|
async fn get_config_handler(conn : @http.ServerConnection) -> Unit {
  let config = get_config()
  // Return the actual configuration, but hide sensitive information
  conn
  ..send_response(200, "OK", extra_headers={
    "Content-Type": "application/json",
  })
  ..write(config.to_json().stringify())
  .end_response()
}

///|
async fn status_handler(conn : @http.ServerConnection) -> Unit {
  let all_peers = get_global_peer_manager().get_all_peers()

  // Add myself to the peers list to show my connections
  let my_config = get_config()
  let my_id = my_config.id
  let my_pk = get_public_key()
  let my_addrs = my_config.listeners.map(addr => {
    addr.replace(old="0.0.0.0", new="127.0.0.1")
  })

  // Get my active direct connections
  let all_conns = get_global_connection_manager().get_all_connections()
  let my_connections : Array[PeerConnectionInfo] = []
  for conn in all_conns {
    if conn.relay == 1 {
      let elapsed_ms = @env.now() - conn.last_seen
      let bandwidth_mbps = conn.calculate_bandwidth_mbps(elapsed_ms)
      let packet_loss_rate = conn.calculate_packet_loss()
      my_connections.push(PeerConnectionInfo::{
        peer_id: conn.peer_id,
        ports: conn.ports,
        latency_ms: conn.latency_ms,
        bandwidth_mbps,
        packet_loss_rate,
        id: conn.id,
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
        nat_type: conn.nat_type,
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
    listeners: config.listeners,
    known_peers,
    routes: routes_info,
  }
  conn
  ..send_response(200, "OK", extra_headers={
    "Content-Type": "application/json",
  })
  ..write(status_info.to_json().stringify())
  .end_response()
}

///|
async fn notfound_handler(conn : @http.ServerConnection) -> Unit {
  conn
  ..send_response(404, "Not Found", extra_headers={
    "Content-Type": "text/html",
  })
  ..write(PAGE_404)
  .end_response()
}

///|
async fn download_handler(conn : @http.ServerConnection) -> Unit {
  let args = @env.args()
  let exe_path = if args.length() > 0 { args[0] } else { "./msgtier" }
  try {
    let file = @fs.open(exe_path, mode=ReadOnly)
    defer file.close()
    conn
    ..send_response(200, "OK", extra_headers={
      "Content-Type": "application/octet-stream",
      "Content-Disposition": "attachment; filename=\"msgtier\"",
    })
    ..write_reader(file)
    .end_response()
  } catch {
    e =>
      conn
      ..send_response(500, "Internal Server Error", extra_headers={
        "Content-Type": "application/json",
      })
      ..write({ "error": e.to_string() }.to_json().stringify())
      .end_response()
  }
}
