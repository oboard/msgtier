///|
/// HTTP handlers for port scanning and mapping management.
///
/// Handlers return `Json` directly (mocket treats `Json` as a `&Responder`)
/// or an `@mocket.HttpResponse` when a non-200 status is needed. Error bodies
/// follow the `{ "error": code, "message": msg }` shape.

///|
/// Request body for `POST /api/port_mappings`. Parsed via `derive(FromJson)`
/// through `event.req.json()`.
struct CreateMappingRequest {
  peer_id : String
  remote_protocol : String
  remote_host : String?
  remote_port : Int
  local_host : String?
  local_port : Int?
  note : String?
} derive(FromJson)

///|
/// Request body for `PATCH /api/port_mappings/:id`. Both fields optional.
struct PatchMappingRequest {
  enabled : Bool?
  note : String?
} derive(FromJson)

///|
fn json_error(
  status : @mocket.StatusCode,
  code : String,
  message : String,
) -> @mocket.HttpResponse {
  @mocket.HttpResponse::new(status).body(
    ({ "error": code.to_json(), "message": message.to_json() } : Json),
  )
}

///|
fn handle_port_scan_local() -> Json {
  let items : Array[Json] = []
  for e in port_scanner_state.last_scan {
    items.push(e.to_json())
  }
  { "ports": items.to_json() }
}

///|
fn handle_port_scan_peers() -> Json {
  let peers_obj : Map[String, Json] = {}
  for peer_id, entries in port_scanner_state.remote_ports_by_peer {
    let items : Array[Json] = []
    for e in entries {
      items.push(e.to_json())
    }
    let last_updated = port_scanner_state.remote_last_updated
      .get(peer_id)
      .unwrap_or(0UL)
    peers_obj[peer_id] = {
      "last_updated": last_updated.to_string().to_json(),
      "ports": items.to_json(),
    }
  }
  { "peers": Json::object(peers_obj) }
}

///|
async fn handle_port_scan_refresh() -> Json {
  let entries = perform_port_scan_cycle(true)
  { "scanned": entries.length().to_json(), "broadcast": true }
}

///|
fn handle_port_mappings_list() -> Json {
  let items : Array[Json] = []
  for m in list_port_mapping_rules() {
    items.push(m.to_json())
  }
  { "mappings": items.to_json() }
}

///|
/// Body:
/// ```
/// { peer_id, remote_protocol, remote_host?, remote_port,
///   local_host?, local_port?, note? }
/// ```
async fn handle_port_mappings_create(
  event : @mocket.MocketEvent,
) -> @mocket.HttpResponse {
  let req : CreateMappingRequest = event.req.json() catch {
    _ =>
      return json_error(
        BadRequest,
        "invalid_body",
        "request body must match schema",
      )
  }
  guard req.peer_id != "" else {
    return json_error(BadRequest, "missing_field", "peer_id required")
  }
  let rule = create_port_mapping_rule(
    req.peer_id,
    req.remote_protocol,
    req.remote_host.unwrap_or("127.0.0.1"),
    req.remote_port,
    req.local_host,
    req.local_port,
    req.note,
  ) catch {
    PortMappingError::DuplicatePort(p) =>
      return json_error(
        Conflict,
        "port_in_use",
        "local port \{p} already claimed by another mapping",
      )
    PortMappingError::InvalidProtocol(p) =>
      return json_error(
        BadRequest,
        "invalid_protocol",
        "unsupported protocol: \{p}",
      )
    PortMappingError::InvalidPort(p) =>
      return json_error(BadRequest, "invalid_port", "port out of range: \{p}")
    PortMappingError::AllocationFailed =>
      return json_error(
        Conflict,
        "allocation_failed",
        "could not find a free local port",
      )
    PortMappingError::NotFound(id) =>
      return json_error(NotFound, "not_found", "mapping \{id} not found")
    _ =>
      return json_error(InternalServerError, "internal_error", "create failed")
  }
  @mocket.HttpResponse::new(OK).body(rule.to_json())
}

///|
async fn handle_port_mappings_delete(id : String) -> @mocket.HttpResponse {
  delete_port_mapping_rule(id) catch {
    PortMappingError::NotFound(id) =>
      return json_error(NotFound, "not_found", "mapping \{id} not found")
    _ =>
      return json_error(InternalServerError, "internal_error", "delete failed")
  }
  @mocket.HttpResponse::new(OK).body(({ "removed": true } : Json))
}

///|
async fn handle_port_mappings_patch(
  id : String,
  event : @mocket.MocketEvent,
) -> @mocket.HttpResponse {
  let req : PatchMappingRequest = event.req.json() catch {
    _ =>
      return json_error(
        BadRequest,
        "invalid_body",
        "request body must match schema",
      )
  }
  let rule = update_port_mapping_rule(id, req.enabled, req.note) catch {
    PortMappingError::NotFound(id) =>
      return json_error(NotFound, "not_found", "mapping \{id} not found")
    _ =>
      return json_error(InternalServerError, "internal_error", "update failed")
  }
  @mocket.HttpResponse::new(OK).body(rule.to_json())
}
