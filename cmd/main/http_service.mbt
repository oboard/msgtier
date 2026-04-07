///|
struct WsClient {
  conn : @websocket.Conn
  sending : Ref[Bool]
}

///|
struct HttpServiceState {
  ws_clients : Map[String, WsClient]
  last_emitted_ids : Map[String, UInt64]
  last_emitted_order : Array[String]
  page_404 : Bytes
  mut chat_engine : @sqlite3.SQLiteEngine?
  mut chat_mapper : @db.MessageMapperImpl?
}

///|
let http_state : HttpServiceState = {
  ws_clients: {},
  last_emitted_ids: {},
  last_emitted_order: [],
  page_404: b"<html><head></head><body>Page Not Found</body></html>",
  chat_engine: None,
  chat_mapper: None,
}

///|
async fn emit_ws_message(msg : Message) -> Unit {
  if !is_persistable_chat_kind(msg.kind) {
    return
  }

  persist_chat_message(msg)

  let now = @env.now()
  let id = msg.id
  match http_state.last_emitted_ids.get(id) {
    Some(ts) => if now - ts < 10000UL { return }
    None => ()
  }

  http_state.last_emitted_ids[id] = now
  http_state.last_emitted_order.push(id)

  while http_state.last_emitted_order.length() > 1000 {
    let old_id = http_state.last_emitted_order[0]
    http_state.last_emitted_order.remove(0) |> ignore
    http_state.last_emitted_ids.remove(old_id)
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
  let clients = []
  for client_id, client in http_state.ws_clients {
    clients.push((client_id, client))
  }
  for pair in clients {
    let (client_id, client) = pair
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
    http_state.ws_clients.remove(client_id)
  }
}

///|
async fn handle_ws_incoming(text : String) -> String? {
  let json_val = @json.parse(text) catch {
    _ => {
      log_warn("WS: invalid json payload")
      return None
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
        return Some(kind)
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
        version=app_state.version,
        timeout_ms=30000,
      )

      let target_display = target_id_opt.unwrap_or("broadcast")
      log_info(
        "WS: Received chat message kind=\{kind} target=\{target_display}",
      )
      add_pending_message(msg)
      emit_ws_message(msg)
      Some(kind)
    }
    _ => {
      log_warn("WS: invalid payload format (expected Object)")
      None
    }
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
    let sending_lock = Ref::new(false)
    http_state.ws_clients[client_addr] = WsClient::{
      conn: ws,
      sending: sending_lock,
    }
    defer {
      ws.close()
      http_state.ws_clients.remove(client_addr)
    }
    for ;; {
      let msg = ws.recv()
      match msg.kind {
        Text => {
          let text = msg.read_all().text()
          if text != "" {
            match handle_ws_incoming(text) {
              Some(kind) =>
                if kind == "ping" {
                  while sending_lock.val {
                    @async.sleep(1)
                  }
                  sending_lock.val = true
                  try {
                    ws.send_text("{\"kind\":\"pong\"}")
                    sending_lock.val = false
                  } catch {
                    _ => sending_lock.val = false
                  }
                }
              None => ()
            }
          }
        }
        Binary => {
          let bytes = msg.read_all().binary()
          let content = @utf8.decode(bytes)
          if content != "" {
            match handle_ws_incoming(content) {
              Some(kind) =>
                if kind == "ping" {
                  while sending_lock.val {
                    @async.sleep(1)
                  }
                  sending_lock.val = true
                  try {
                    ws.send_text("{\"kind\":\"pong\"}")
                    sending_lock.val = false
                  } catch {
                    _ => sending_lock.val = false
                  }
                }
              None => ()
            }
          }
        }
      }
    }
  } catch {
    _ => ()
  }
}

///|
async fn handle_http_request(
  root : @async.TaskGroup[Unit],
  request : @http.Request,
  body : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  if request is { meth: Post, path: "/api/object", .. } {
    handle_object_upload(request, body, conn)
    return
  }
  if request is { meth: Post, path: "/api/object/register", .. } {
    handle_object_registration(body, conn)
    return
  }
  if request is { meth: Post, path: "/api/channels/chat", .. } {
    let body_str = body.read_all().text()
    channel_chat_handler(conn, body_str, false)
    return
  }
  if request is { meth: Post, path: "/api/channels/chat/stream", .. } {
    let body_str = body.read_all().text()
    channel_chat_stream_handler(conn, body_str, false)
    return
  }
  if request is { meth: Post, path: "/api/channels/chat/local", .. } {
    let body_str = body.read_all().text()
    channel_chat_handler(conn, body_str, true)
    return
  }
  if request is { meth: Post, path: "/api/channels/chat/local/stream", .. } {
    let body_str = body.read_all().text()
    channel_chat_stream_handler(conn, body_str, true)
    return
  }
  if request is { meth: Post, path: "/api/openclaw/chat", .. } {
    let body_str = body.read_all().text()
    openclaw_chat_handler(conn, body_str, false)
    return
  }
  if request is { meth: Post, path: "/api/openclaw/chat/local", .. } {
    let body_str = body.read_all().text()
    openclaw_chat_handler(conn, body_str, true)
    return
  }

  if request is { meth: Get, path, .. } &&
    @url.Url::parse("http://localhost" + path)
    is Some({ path: Segments(["api", "object", id]), query, .. }) {
    let mut peer_id = None
    let mut filename = None
    if query is Some(query) {
      let parts = query.split("&")
      for part in parts {
        let part_str = part.to_string()
        if part_str.has_prefix("peer=") {
          peer_id = Some(part_str[5:].to_string())
        } else if part_str.has_prefix("filename=") {
          filename = Some(part_str[9:].to_string())
        }
      }
    }

    handle_object_download(root, id, peer_id, filename, request.headers, conn)
    return
  }

  if request is { meth: Get, path, .. } &&
    @url.Url::parse("http://localhost" + path)
    is Some({ path: Segments(["api", "chat", "messages"]), query, .. }) {
    chat_messages_handler(conn, query)
    return
  }

  if request is { path, .. } &&
    @url.Url::parse("http://localhost" + path)
    is Some({ path: Segments(["api", "proxy"]), query, .. }) {
    let mut peer_id = None
    let mut proxy_path = None
    if query is Some(query) {
      let parts = query.split("&")
      for part in parts {
        let part_str = part.to_string()
        if part_str.has_prefix("peer=") {
          peer_id = Some(part_str[5:].to_string())
        } else if part_str.has_prefix("path=") {
          proxy_path = Some(part_str[5:].to_string())
        }
      }
    }
    if peer_id is None {
      peer_id = request.headers.get("target")
    }
    if proxy_path is None {
      proxy_path = request.headers.get("path")
    }
    match (peer_id, proxy_path) {
      (Some(pid), Some(p)) => {
        let timeout_ms_int = match request.headers.get("timeout") {
          Some(t) => @string.parse_int(t) catch { _ => 60000 }
          None => 60000
        }
        let timeout_ms = if timeout_ms_int < 0 { 60000 } else { timeout_ms_int }
        let forward_headers : Map[String, String] = {}
        for k, v in request.headers {
          if k != "target" && k != "path" && k != "peer" {
            forward_headers[k] = v
          }
        }
        let method_ = request.meth.to_string().to_upper()
        let body_bytes = body.read_all().binary()
        let _ = root.spawn_bg(async fn() {
          match
            proxy_http_request(
              pid, method_, p, forward_headers, body_bytes, timeout_ms,
            ) {
            Some((status_code, resp_headers, resp_body)) => {
              let headers = resp_headers
              if !headers.contains("Content-Length") {
                headers["Content-Length"] = resp_body.length().to_string()
              }
              conn
              ..send_response(
                status_code,
                status_text(status_code),
                extra_headers=headers,
              )
              ..write(resp_body)
              .end_response()
            }
            None =>
              conn
              ..send_response(504, "Gateway Timeout", extra_headers={})
              ..write("Timeout fetching from peer")
              .end_response()
          }
        })
      }
      _ =>
        conn
        ..send_response(400, "Bad Request", extra_headers={})
        ..write("Missing peer or path")
        .end_response()
    }
    return
  }

  match (request.meth, request.path) {
    (Get, "/api/ws") => handle_ws_connection(request, conn)
    (Get, "/api/chat/messages") => chat_messages_handler(conn, None)
    (Get, "/api/config") => get_config_handler(conn)
    (Post, "/api/config/hot-reload") => {
      let body_str = body.read_all().text()
      hot_reload_config_handler(conn, body_str)
    }
    (Get, "/api/status") => status_handler(conn)
    (Get, "/api/download") => download_handler(conn)
    (Post, "/api/send") => {
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

      let timeout_ms_int = match request.headers.get("timeout") {
        Some(t) => @string.parse_int(t) catch { _ => 10000 }
        None => 10000
      }
      let timeout_ms = if timeout_ms_int < 0 { 10000 } else { timeout_ms_int }
      let timeout_ms_uint = timeout_ms.reinterpret_as_uint()
      let kind = match request.headers.get("kind") {
        Some(k) => k
        None => "script"
      }

      let body_str = body.read_all().text()
      let config = get_config()
      let my_id = config.id
      let addrs = config.listeners
      let local_addr = if addrs.is_empty() { "127.0.0.1:0" } else { addrs[0] }

      let is_self = target_id.trim() == my_id
      let data_val = @msgpack.string(body_str)
      let is_encrypted = !is_self && config.is_encrypt()

      let msg = Message::new(
        kind~,
        source_id=my_id,
        relay=1,
        version=app_state.version,
        target_id~,
        body=data_val,
        encrypted=is_encrypted,
        timeout_ms=timeout_ms_uint,
      )
      let msg = { ..msg, payload: Some(msg.id) }

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

      let target_peer = get_global_peer_manager().get_peer(target_id)
      let is_self = target_id == my_id
      match (target_peer, is_self) {
        (Some(_), _) | (None, true) => {
          add_pending_request(msg.id)
          add_pending_message(msg)
          ignore(send_message_now(target_id, msg))
          log_debug("HTTP /send: Registered request id=\{msg.id}")

          match wait_for_response(msg.id, timeout_ms_uint) {
            Some((response, headers)) =>
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
async fn start_http_service(
  root : @async.TaskGroup[Unit],
  addr : String,
) -> Unit {
  init_upload_dir()
  init_chat_store()
  for ;; {
    try {
      let server = @http.Server::new(@socket.Addr::parse(addr), reuse_addr=true)
      server.run_forever((req, body, conn) => {
        handle_http_request(root, req, body, conn)
      })
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
  @web.ensure_dist_loaded()
  let path = if path == "/" { "index.html" } else { path }
  if path.contains("..") {
    notfound_handler(conn)
    return
  }
  if @web.dist.get(path[1:]) is Some(bytes) {
    serve_file(conn, bytes, path)
  } else {
    serve_file(conn, @web.dist["index.html"], "index.html")
  }
}

///|
async fn serve_file(
  conn : @http.ServerConnection,
  file : Bytes,
  path : String,
) -> Unit {
  try {
    let content_type = match path {
      [.., .. ".html"] => "text/html"
      [.., .. ".css"] => "text/css"
      [.., .. ".js"] => "text/javascript"
      [.., .. ".json"] => "application/json"
      [.., .. ".png"] => "image/png"
      [.., .. ".jpg"] | [.., .. ".jpeg"] => "image/jpeg"
      [.., .. ".svg"] => "image/svg+xml"
      [.., .. ".ico"] => "image/x-icon"
      _ => "application/octet-stream"
    }
    conn
    ..send_response(200, "OK", extra_headers={ "Content-Type": content_type })
    ..write(file)
    .end_response()
  } catch {
    _ => ()
  }
}

///|
async fn get_config_handler(conn : @http.ServerConnection) -> Unit {
  conn
  ..send_response(200, "OK", extra_headers={
    "Content-Type": "application/json",
  })
  ..write(get_config_response_json().stringify())
  .end_response()
}

///|
async fn hot_reload_config_handler(
  conn : @http.ServerConnection,
  body_str : String,
) -> Unit {
  match apply_hot_reload_request(body_str) {
    Ok(_) =>
      conn
      ..send_response(200, "OK", extra_headers={
        "Content-Type": "application/json",
      })
      ..write(get_config_response_json().stringify())
      .end_response()
    Err(err) =>
      conn
      ..send_response(400, "Bad Request", extra_headers={
        "Content-Type": "application/json",
      })
      ..write({ "error": err }.to_json().stringify())
      .end_response()
  }
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

  let my_addrs = my_config.listeners.map(addr => {
    addr.replace(old="0.0.0.0", new="127.0.0.1")
  })

  let all_conns = get_global_connection_manager().get_all_connections()
  let my_connections : Array[PeerConnectionInfo] = []
  for conn in all_conns {
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
  let me = PeerNode::new(
    id=my_id,
    version=app_state.version,
    addresses=my_addrs,
    metadata=get_local_node_metadata(),
  )
  let me_with_conns = { ..me, connections: my_connections }
  all_peers.push(me_with_conns)

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
    stun: stun_discovery_state.values().to_array(),
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
  ..write(http_state.page_404)
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
