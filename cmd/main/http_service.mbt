///|
/// HTTP service backed by the mocket framework.
///
/// Each handler returns a mocket `HttpResponse` or a `Json` (which mocket
/// treats as a JSON body via its `Responder` impl).  WebSocket upgrade for
/// `/api/ws` is handled by mocket's channel-based pub/sub.

///|
struct HttpServiceState {
  last_emitted_ids : Map[String, UInt64]
  last_emitted_order : Array[String]
  page_404 : Bytes
  mut chat_engine : @sqlite3.SQLiteEngine?
  mut chat_mapper : @db.MessageMapperImpl?
}

///|
let http_state : HttpServiceState = {
  last_emitted_ids: {},
  last_emitted_order: [],
  page_404: b"<html><head></head><body>Page Not Found</body></html>",
  chat_engine: None,
  chat_mapper: None,
}

///|
/// Every websocket subscriber is joined to this channel so that new chat
/// messages published via [emit_ws_message] fan out to all clients.
let ws_chat_channel : String = "chat"

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
  @mocket.ws_publish(ws_chat_channel, m.stringify())
}

///|
/// Dispatch an inbound WebSocket text frame to the chat pipeline.
///
/// Returns the message kind so callers can respond to pings.
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
          let mp_map : Map[String, @msgpack.Value] = Map([], capacity=0)
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

///|
fn view_map_from_string_map(
  m : Map[String, String],
) -> Map[StringView, StringView] {
  let out : Map[StringView, StringView] = {}
  for k, v in m {
    out[k[:]] = v[:]
  }
  out
}

///|
fn owned_headers(headers : Map[StringView, StringView]) -> Map[String, String] {
  let out : Map[String, String] = {}
  for k, v in headers {
    out[k.to_owned()] = v.to_owned()
  }
  out
}

///|
/// Split `raw` at the first occurrence of `sep`.  Returns `None` if `sep` is
/// absent.  Used for parsing "k=v" query params without needing a real find.
fn split_once(raw : String, sep : String) -> (String, String)? {
  let parts = raw.split(sep).to_array()
  if parts.length() < 2 {
    return None
  }
  let head = parts[0].to_owned()
  let mut tail = ""
  for i = 1; i < parts.length(); i = i + 1 {
    if i > 1 {
      tail = tail + sep
    }
    tail = tail + parts[i].to_owned()
  }
  Some((head, tail))
}

///|
fn parse_query_map(raw : String?) -> Map[String, String] {
  let out : Map[String, String] = {}
  match raw {
    Some(q) if q != "" =>
      for pair in q.split("&") {
        let s = pair.to_owned()
        match split_once(s, "=") {
          Some((k, v)) => out[k] = v
          None => out[s] = ""
        }
      }
    _ => ()
  }
  out
}

///|
/// Extract the query string from a mocket request URL: everything after `?`.
fn request_query(req : @mocket.HttpRequest) -> String? {
  match split_once(req.url, "?") {
    Some((_, q)) => if q == "" { None } else { Some(q) }
    None => None
  }
}

///|
fn get_config_handler() -> Json {
  get_config_response_json()
}

///|
fn hot_reload_config_handler(body_str : String) -> @mocket.HttpResponse {
  match apply_hot_reload_request(body_str) {
    Ok(_) => @mocket.HttpResponse::new(OK).body(get_config_response_json())
    Err(err) => json_error(BadRequest, "hot_reload_failed", err)
  }
}

///|
fn status_handler() -> Json {
  let my_config = get_config()
  let my_id = my_config.id
  let raw_peers = get_global_peer_manager().get_all_peers()
  let all_peers : Array[PeerNode] = []
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
  let status_info = StatusInfo::{
    status: "ok",
    peers: all_peers,
    peers_count: all_peers.length(),
    peer_id: my_id,
    listeners: my_config.listeners,
    known_peers,
    routes: routes_info,
    stun: stun_discovery_state.values().to_array(),
  }
  status_info.to_json()
}

///|
/// Read the executable back over HTTP for lightweight self-distribution.
async fn download_handler() -> @mocket.HttpResponse {
  let args = @env.args()
  let exe_path = if args.length() > 0 { args[0] } else { "./msgtier" }
  let bytes = @fs.read_file(exe_path).binary() catch {
    e =>
      return json_error(
        InternalServerError,
        "read_failed",
        "failed to read executable: \{e}",
      )
  }
  @mocket.HttpResponse::new(
    OK,
    headers={
      "Content-Type": "application/octet-stream",
      "Content-Disposition": "attachment; filename=\"msgtier\"",
    },
    raw_body=bytes,
  )
}

///|
async fn send_message_handler(
  headers : Map[StringView, StringView],
  body_str : String,
) -> @mocket.HttpResponse {
  let target_id = match headers.get("target") {
    Some(v) => v.to_owned()
    None =>
      return json_error(BadRequest, "missing_target", "Missing target header")
  }
  let timeout_ms_int = match headers.get("timeout") {
    Some(t) => @string.parse_int(t.to_owned()) catch { _ => 10000 }
    None => 10000
  }
  let timeout_ms = if timeout_ms_int < 0 { 10000 } else { timeout_ms_int }
  let timeout_ms_uint = timeout_ms.reinterpret_as_uint()
  let kind = match headers.get("kind") {
    Some(k) => k.to_owned()
    None => "script"
  }
  let config = get_config()
  let my_id = config.id
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
  log_info("HTTP /send: Queuing message id=\{msg.id} to \{target_id}")
  let target_peer = get_global_peer_manager().get_peer(target_id)
  match (target_peer, is_self) {
    (Some(_), _) | (None, true) => {
      add_pending_request(msg.id)
      add_pending_message(msg)
      ignore(send_message_now(target_id, msg))
      match wait_for_response(msg.id, timeout_ms_uint) {
        Some((response, response_headers)) =>
          @mocket.HttpResponse::new(
            OK,
            headers=view_map_from_string_map(response_headers),
            raw_body=response,
          )
        None =>
          json_error(
            GatewayTimeout,
            "timeout",
            "Request timed out to \{target_id}",
          )
      }
    }
    (None, false) =>
      json_error(
        NotFound,
        "peer_not_found",
        "Target peer \{target_id} not found",
      )
  }
}

///|
async fn proxy_handler(
  method_ : String,
  headers : Map[StringView, StringView],
  query : String?,
  body : Bytes,
) -> @mocket.HttpResponse {
  let query_map = parse_query_map(query)
  let peer_id = match query_map.get("peer") {
    Some(v) => Some(v)
    None => headers.get("target").map(v => v.to_owned())
  }
  let proxy_path = match query_map.get("path") {
    Some(v) => Some(v)
    None => headers.get("path").map(v => v.to_owned())
  }
  match (peer_id, proxy_path) {
    (Some(pid), Some(p)) => {
      let timeout_ms_int = match headers.get("timeout") {
        Some(t) => @string.parse_int(t.to_owned()) catch { _ => 60000 }
        None => 60000
      }
      let timeout_ms = if timeout_ms_int < 0 { 60000 } else { timeout_ms_int }
      let forward_headers : Map[String, String] = {}
      for k, v in headers {
        let key = k.to_owned()
        if key != "target" && key != "path" && key != "peer" {
          forward_headers[key] = v.to_owned()
        }
      }
      match
        proxy_http_request(pid, method_, p, forward_headers, body, timeout_ms) {
        Some((status_code, resp_headers, resp_body)) => {
          if !resp_headers.contains("Content-Length") {
            resp_headers["Content-Length"] = resp_body.length().to_string()
          }
          @mocket.HttpResponse::new(
            @mocket.StatusCode::from_int(status_code),
            headers=view_map_from_string_map(resp_headers),
            raw_body=resp_body,
          )
        }
        None =>
          json_error(GatewayTimeout, "timeout", "Timeout fetching from peer")
      }
    }
    _ => json_error(BadRequest, "missing_params", "Missing peer or path")
  }
}

///|
/// Look up an object by id, first via the local store then via peers.
async fn handle_object_get(
  id : String,
  filename : String?,
  request_headers : Map[String, String],
) -> @mocket.HttpResponse {
  match get_object_path(id) {
    Some(path) => {
      let bytes = @fs.read_file(path).binary() catch {
        _ =>
          return json_error(
            NotFound,
            "object_not_found",
            "object \{id} could not be read",
          )
      }
      let (status_code, resp_headers, body) = build_object_download_response(
        bytes, filename, request_headers,
      )
      @mocket.HttpResponse::new(
        @mocket.StatusCode::from_int(status_code),
        headers=view_map_from_string_map(resp_headers),
        raw_body=body,
      )
    }
    None =>
      match get_object(id) {
        Some(data) => {
          let (status_code, resp_headers, body) = build_object_download_response(
            data, filename, request_headers,
          )
          @mocket.HttpResponse::new(
            @mocket.StatusCode::from_int(status_code),
            headers=view_map_from_string_map(resp_headers),
            raw_body=body,
          )
        }
        None =>
          json_error(NotFound, "object_not_found", "object \{id} not found")
      }
  }
}

///|
/// Serve a static asset out of the embedded web/dist bundle.
fn serve_static_handler(path : String) -> @mocket.HttpResponse {
  @web.ensure_dist_loaded()
  let normalized = if path == "/" { "index.html" } else { path }
  if normalized.contains("..") {
    return @mocket.HttpResponse::new(NotFound, raw_body=http_state.page_404)
  }
  let key = if normalized.has_prefix("/") {
    normalized[1:].to_owned()
  } else {
    normalized
  }
  let (bytes, content_type) = match @web.dist.get(key) {
    Some(bytes) => (bytes, content_type_for(key))
    None => (@web.dist["index.html"], "text/html")
  }
  @mocket.HttpResponse::new(
    OK,
    headers={ "Content-Type": content_type },
    raw_body=bytes,
  )
}

///|
fn content_type_for(path : String) -> String {
  if path.has_suffix(".html") {
    "text/html"
  } else if path.has_suffix(".css") {
    "text/css"
  } else if path.has_suffix(".js") {
    "text/javascript"
  } else if path.has_suffix(".json") {
    "application/json"
  } else if path.has_suffix(".png") {
    "image/png"
  } else if path.has_suffix(".jpg") || path.has_suffix(".jpeg") {
    "image/jpeg"
  } else if path.has_suffix(".svg") {
    "image/svg+xml"
  } else if path.has_suffix(".ico") {
    "image/x-icon"
  } else {
    "application/octet-stream"
  }
}

///|
fn ws_chat_handler(event : @mocket.WebSocketEvent) -> Unit {
  match event {
    Open(peer) => peer.subscribe(ws_chat_channel)
    Close(_) => ()
    Message(peer, msg) =>
      match msg {
        Text(text) =>
          if text != "" {
            match app_state.root {
              Some(root) =>
                root.spawn_bg(async fn() {
                  match handle_ws_incoming(text) {
                    Some(kind) =>
                      if kind == "ping" {
                        peer.text("{\"kind\":\"pong\"}")
                      }
                    None => ()
                  }
                })
              None => ()
            }
          }
        Binary(bytes) => {
          let content = @utf8.decode(bytes) catch { _ => "" }
          if content != "" {
            match app_state.root {
              Some(root) =>
                root.spawn_bg(async fn() {
                  match handle_ws_incoming(content) {
                    Some(kind) =>
                      if kind == "ping" {
                        peer.text("{\"kind\":\"pong\"}")
                      }
                    None => ()
                  }
                })
              None => ()
            }
          }
        }
        Ping => peer.pong()
      }
  }
}

///|
/// Register every HTTP + WebSocket route against the mocket instance.
fn register_routes(app : @mocket.Mocket) -> Unit {
  app.ws("/api/ws", ws_chat_handler)
  app.get("/api/status", _ => status_handler())
  app.get("/api/config", _ => get_config_handler())
  app.post("/api/config/hot-reload", e => {
    let body : String = e.req.body() catch { _ => "" }
    hot_reload_config_handler(body)
  })
  app.get("/api/download", _ => {
    download_handler() catch {
      err => json_error(InternalServerError, "download_failed", "\{err}")
    }
  })
  app.post("/api/send", e => {
    try {
      let body : String = e.req.body() catch { _ => "" }
      send_message_handler(e.req.headers, body)
    } catch {
      err => json_error(InternalServerError, "send_failed", "\{err}")
    }
  })
  app.all("/api/proxy", e => {
    try {
      let body : Bytes = e.req.body() catch { _ => b"" }
      let query = request_query(e.req)
      proxy_handler(e.req.http_method, e.req.headers, query, body)
    } catch {
      err => json_error(InternalServerError, "proxy_failed", "\{err}")
    }
  })
  app.get("/api/chat/messages", e => {
    try {
      let query = request_query(e.req)
      @mocket.HttpResponse::new(OK).body(chat_messages_handler(query))
    } catch {
      err => json_error(InternalServerError, "chat_history_failed", "\{err}")
    }
  })
  app.post("/api/channels/chat", e => {
    try {
      let body : String = e.req.body() catch { _ => "" }
      channel_chat_handler(body, false)
    } catch {
      err => json_error(InternalServerError, "channel_chat_failed", "\{err}")
    }
  })
  app.post("/api/channels/chat/local", e => {
    try {
      let body : String = e.req.body() catch { _ => "" }
      channel_chat_handler(body, true)
    } catch {
      err => json_error(InternalServerError, "channel_chat_failed", "\{err}")
    }
  })
  app.post("/api/object", e => {
    try {
      let body : Bytes = e.req.body() catch { _ => b"" }
      let id = @nanoid.nanoid().unwrap_or(@env.now().to_string())
      save_object(id, body)
      @mocket.HttpResponse::new(OK).body(({ "id": id.to_json() } : Json))
    } catch {
      err => json_error(InternalServerError, "object_upload_failed", "\{err}")
    }
  })
  app.post("/api/object/register", e => {
    let body : String = e.req.body() catch { _ => "" }
    let json_val = @json.parse(body) catch {
      _ => return json_error(BadRequest, "invalid_json", "invalid json payload")
    }
    let path = match json_val {
      Object({ "path": String(s), .. }) => s
      _ => ""
    }
    if path == "" {
      return json_error(BadRequest, "missing_field", "path required")
    }
    let id = register_object(path)
    @mocket.HttpResponse::new(OK).body(({ "id": id.to_json() } : Json))
  })
  app.get("/api/object/:id", e => {
    try {
      let id = e.params.get("id").map(s => s.to_owned()).unwrap_or("")
      let query_map = parse_query_map(request_query(e.req))
      let filename = query_map.get("filename")
      let request_headers = owned_headers(e.req.headers)
      handle_object_get(id, filename, request_headers)
    } catch {
      err => json_error(InternalServerError, "object_get_failed", "\{err}")
    }
  })
  app.get("/api/port_scan/local", _ => handle_port_scan_local())
  app.get("/api/port_scan/peers", _ => handle_port_scan_peers())
  app.post("/api/port_scan/refresh", _ => {
    @mocket.HttpResponse::new(OK).body(handle_port_scan_refresh()) catch {
      err => json_error(InternalServerError, "scan_failed", "\{err}")
    }
  })
  app.get("/api/port_mappings", _ => handle_port_mappings_list())
  app.post("/api/port_mappings", e => {
    handle_port_mappings_create(e) catch {
      err => json_error(InternalServerError, "mapping_create_failed", "\{err}")
    }
  })
  app.delete("/api/port_mappings/:id", e => {
    try {
      let id = e.params.get("id").map(s => s.to_owned()).unwrap_or("")
      handle_port_mappings_delete(id)
    } catch {
      err => json_error(InternalServerError, "mapping_delete_failed", "\{err}")
    }
  })
  app.patch("/api/port_mappings/:id", e => {
    try {
      let id = e.params.get("id").map(s => s.to_owned()).unwrap_or("")
      handle_port_mappings_patch(id, e)
    } catch {
      err => json_error(InternalServerError, "mapping_patch_failed", "\{err}")
    }
  })

  // Fallback: serve embedded static SPA for anything not matched above.
  app.get("/", _ => serve_static_handler("/"))
  app.get("/:path", e => {
    let p = e.params.get("path").map(s => "/" + s.to_owned()).unwrap_or("/")
    serve_static_handler(p)
  })
  app.get("/assets/:path", e => {
    let p = e.params
      .get("path")
      .map(s => "/assets/" + s.to_owned())
      .unwrap_or("/index.html")
    serve_static_handler(p)
  })
}

///|
async fn start_http_service(
  _root : @async.TaskGroup[Unit],
  addr : String,
) -> Unit {
  init_upload_dir()
  init_chat_store()
  let app = @mocket.new()
  register_routes(app)
  for ;; {
    log_info("mocket HTTP listening on \{addr}")
    app.listen(addr)
    log_warn("mocket HTTP server on \{addr} exited; retrying in 5s")
    @async.sleep(5000)
  }
}
