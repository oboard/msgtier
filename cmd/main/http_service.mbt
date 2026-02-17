///|
const PAGE_404 : Bytes = b"<html><head></head><body>Page Not Found</body></html>"

///|
struct WsClient {
  conn : @websocket.Conn
  sending : Ref[Bool]
}

///|
let ws_clients : Ref[Map[String, WsClient]] = Ref::new({})

///|

///|

///|
async fn emit_ws_message(msg : Message) -> Unit {
  if msg.kind != "text" && msg.kind != "file" && msg.kind != "image" {
    return
  }

  let m : Json = {
    "id": msg.id,
    "kind": msg.kind,
    "source_id": msg.source_id,
    "target_id": msg.target_id.unwrap_or("broadcast"),
    "timestamp": msg.timestamp.to_double(),
    "content": msg.body.to_json(),
  }

  let json_str = m.stringify()
  let to_remove = []
  // Snapshot clients to avoid concurrent modification issues during async loop
  let clients = []
  for client_id, client in ws_clients.val {
    clients.push((client_id, client))
  }
  for pair in clients {
    let (client_id, client) = pair
    // Spinlock to prevent concurrent writes
    while client.sending.val {
      @async.sleep(1)
    }
    client.sending.val = true
    try {
      client.conn.send_text(json_str)
      client.sending.val = false
    } catch {
      _ => {
        client.sending.val = false
        to_remove.push(client_id)
      }
    }
  }
  for client_id in to_remove {
    ws_clients.val.remove(client_id)
  }
}

///|
fn handle_ws_incoming(text : String) -> Unit {
  let json_val = @json.parse(text) catch {
    _ => {
      log_warn("WS: invalid json payload")
      return
    }
  }

  match json_val {
    Object(m) => {
      let target_val = m.get("target")
      let kind_val = m.get("kind")
      let content_val = m.get("content")

      let target_id_opt = match target_val {
        Some(String(t)) => if t == "broadcast" { None } else { Some(t) }
        _ => None
      }

      let kind = match kind_val {
        Some(String(k)) => k
        _ => "text"
      }

      if kind == "ping" || kind == "pong" || kind == "sync" {
        return
      }

      let body = match (kind, content_val) {
        ("text", Some(String(s))) => @msgpack.string(s)
        ("file", Some(Object(fields))) | ("image", Some(Object(fields))) => {
          let mp_map : Map[String, @msgpack.Value] = Map::new()
          for k, v in fields {
            let mp_val = match v {
              String(s) => @msgpack.string(s)
              Number(n, ..) => @msgpack.int64(n.to_int64())
              _ => @msgpack.nil()
            }
            mp_map[k] = mp_val
          }
          @msgpack.map(mp_map)
        }
        _ => @msgpack.nil()
      }

      let config = get_config()
      let my_id = config.id

      let msg = Message::new(
        kind~,
        source_id=my_id,
        target_id?=target_id_opt,
        body~,
        relay=1,
        version=VERSION,
        timeout_ms=30000UL,
      )

      let target_display = target_id_opt.unwrap_or("broadcast")
      log_info(
        "WS: Received chat message kind=\{kind} target=\{target_display}",
      )
      add_pending_message(msg)
    }
    _ => log_warn("WS: invalid payload format (expected Object)")
  }
}

///|
async fn handle_ws_connection(
  request : @http.Request,
  conn : @http.ServerConnection,
) -> Unit {
  let client_addr = conn.client_addr().to_string()
  try {
    let ws = @websocket.from_http_server(request, conn)
    ws_clients.val[client_addr] = WsClient::{
      conn: ws,
      sending: Ref::new(false),
    }
    defer {
      ws.close()
      ws_clients.val.remove(client_addr)
    }
    for {
      let msg = ws.recv()
      match msg.kind {
        Text => {
          let text = msg.read_all().text()
          if text != "" {
            handle_ws_incoming(text)
          }
        }
        Binary => {
          // Fallback for binary messages (e.g. legacy or other clients)
          let bytes = msg.read_all().binary()
          let content = @utf8.decode(bytes)
          if content != "" {
            handle_ws_incoming(content)
          }
        }
      }
    }
  } catch {
    _ => ()
  }
}

///|
async fn handle_object_upload(
  _request : @http.Request,
  body : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  let bytes = body.read_all().binary()
  let id = save_object(bytes)

  let m = Map::new()
  m["id"] = id.to_json()
  let json_str = m.to_json().stringify()

  conn
  ..send_response(200, "OK", extra_headers={
    "Content-Type": "application/json",
  })
  ..write(json_str)
  .end_response()
}

///|
async fn handle_object_download(
  id : String,
  peer_id : String?,
  conn : @http.ServerConnection,
) -> Unit {
  match get_object(id) {
    Some(data) =>
      conn
      ..send_response(200, "OK", extra_headers={
        "Content-Type": "application/octet-stream",
        "Content-Length": data.length().to_string(),
      })
      ..write(data)
      .end_response()
    None =>
      match peer_id {
        Some(pid) => {
          log_info("ObjectStore: fetching object id=\{id} from peer=\{pid}")
          let req_id = @uuidm.v4().to_string()
          add_pending_request(req_id)

          let msg = Message::new(
            kind="object_request",
            source_id=get_config().id,
            target_id=pid,
            payload=req_id,
            body=@msgpack.string(id),
            relay=1,
          )
          add_pending_message(msg)

          match wait_for_response(req_id, 10000) {
            Some((data, _)) => {
              log_info("ObjectStore: fetched object id=\{id} size=\{data.length()}")
              // Save to local store for future requests
              let _ = save_object(data, id=id)

              conn
              ..send_response(200, "OK", extra_headers={
                "Content-Type": "application/octet-stream",
                "Content-Length": data.length().to_string(),
              })
              ..write(data)
              .end_response()
            }
            None =>
              conn
              ..send_response(404, "Not Found", extra_headers={})
              ..write("Object not found on peer (timeout)")
              .end_response()
          }
        }
        None =>
          conn
          ..send_response(404, "Not Found", extra_headers={})
          ..write("Object not found")
          .end_response()
      }
  }
}

///|
async fn handle_http_request(
  request : @http.Request,
  body : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  if request.meth == Post && request.path == "/api/object" {
    handle_object_upload(request, body, conn)
    return
  }
  if request.meth == Get && request.path.has_prefix("/api/object/") {
    let path_suffix = request.path[12:].to_string()
    let mut id = path_suffix
    let mut query = ""

    // Find '?' index manually since index_of is missing
    let mut q_idx = -1
    for i = 0; i < path_suffix.length(); i = i + 1 {
      if path_suffix[i] == '?' {
        q_idx = i
        break
      }
    }

    if q_idx != -1 {
      id = path_suffix[:q_idx].to_string()
      query = path_suffix[q_idx + 1:].to_string()
    }

    let mut peer_id : String? = None
    if query != "" {
      // Simple query parser for "peer=..."
      let parts = query.split("&")
      for part in parts {
        if part.has_prefix("peer=") {
          peer_id = Some(part[5:].to_string())
          break
        }
      }
    }

    handle_object_download(id, peer_id, conn)
    return
  }

  match (request.meth, request.path) {
    (Get, "/ws") => handle_ws_connection(request, conn)
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
      let kind = match request.headers.get("kind") {
        Some(k) => k
        None => "script"
      }

      // Read request body (convert from Bytes to String)
      let body_str = body.read_all().text()
      let config = get_config()
      // Get current node ID and local address
      let my_id = config.id
      let addrs = config.listeners
      let local_addr = if addrs.is_empty() { "127.0.0.1:0" } else { addrs[0] }

      // Prepare data payload (encryption handled at send time)
      let is_self = target_id.trim() == my_id
      let data_val = @msgpack.string(body_str)
      let is_encrypted = !is_self

      // Create data message to send with body as data
      let msg = Message::new(
        kind~,
        source_id=my_id,
        relay=1,
        version=VERSION,
        target_id~,
        body=data_val,
        encrypted=is_encrypted,
        timeout_ms~,
      )
      // Set payload as correlation ID for response tracking
      let msg = { ..msg, payload: Some(msg.id) }

      // Print to stdout for debugging
      log_debug("HTTP /send: Queuing message id=\{msg.id} to \{target_id}")
      log_debug("  From: \{my_id}")
      log_debug("  Local: \{local_addr}")
      log_debug("  Kind: \{kind}")
      log_debug("  Data: \{body_str}")
      log_debug("  Self: \{is_self}")
      log_debug("  Encrypted: \{is_encrypted}")
      log_debug("  Timeout: \{timeout_ms}ms")
      log_debug("  DataVal: String len=\{body_str.length()}")
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
  let my_config = get_config()
  let my_id = my_config.id
  let raw_peers = get_global_peer_manager().get_all_peers()
  let all_peers = []
  for p in raw_peers {
    if p.id != my_id {
      all_peers.push(p)
    }
  }

  // Add myself to the peers list to show my connections
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
