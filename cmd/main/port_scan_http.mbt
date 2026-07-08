///|
/// HTTP handlers for port scanning and mapping management.
///
/// Response bodies are JSON with `Content-Type: application/json`.  Errors
/// follow the `{"error": "code", "message": "..."}` shape.

///|
async fn write_json_response(
  conn : @http.ServerConnection,
  status_code : Int,
  payload : Json,
) -> Unit {
  conn
  ..send_response(status_code, status_text(status_code), extra_headers={
    "Content-Type": "application/json",
  })
  ..write(payload.stringify())
  .end_response()
}

///|
async fn write_json_error(
  conn : @http.ServerConnection,
  status_code : Int,
  code : String,
  message : String,
) -> Unit {
  let payload : Json = { "error": code.to_json(), "message": message.to_json() }
  write_json_response(conn, status_code, payload)
}

///|
async fn handle_port_scan_local(conn : @http.ServerConnection) -> Unit {
  let items : Array[Json] = []
  for e in port_scanner_state.last_scan {
    items.push(e.to_json())
  }
  write_json_response(conn, 200, { "ports": items.to_json() })
}

///|
async fn handle_port_scan_peers(conn : @http.ServerConnection) -> Unit {
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
  write_json_response(conn, 200, { "peers": Json::object(peers_obj) })
}

///|
async fn handle_port_scan_refresh(conn : @http.ServerConnection) -> Unit {
  let entries = perform_port_scan_cycle(true)
  write_json_response(conn, 200, {
    "scanned": entries.length().to_json(),
    "broadcast": true,
  })
}

///|
async fn handle_port_mappings_list(conn : @http.ServerConnection) -> Unit {
  let items : Array[Json] = []
  for m in list_port_mapping_rules() {
    items.push(m.to_json())
  }
  write_json_response(conn, 200, { "mappings": items.to_json() })
}

///|
/// Body:
/// ```
/// { peer_id, remote_protocol, remote_host?, remote_port,
///   local_host?, local_port?, note? }
/// ```
async fn handle_port_mappings_create(
  conn : @http.ServerConnection,
  body_str : String,
) -> Unit {
  let obj = @json.parse(body_str) catch {
    _ => {
      write_json_error(conn, 400, "invalid_json", "request body must be JSON")
      return
    }
  }
  let peer_id : String? = @jsonx.get(obj, "peer_id")
  let remote_protocol : String? = @jsonx.get(obj, "remote_protocol")
  let remote_host : String? = @jsonx.get(obj, "remote_host")
  let remote_port : Int? = @jsonx.get(obj, "remote_port")
  let local_host : String? = @jsonx.get(obj, "local_host")
  let local_port : Int? = @jsonx.get(obj, "local_port")
  let note : String? = @jsonx.get(obj, "note")
  guard peer_id is Some(peer_id) && peer_id != "" else {
    write_json_error(conn, 400, "missing_field", "peer_id required")
    return
  }
  guard remote_protocol is Some(remote_protocol) else {
    write_json_error(conn, 400, "missing_field", "remote_protocol required")
    return
  }
  guard remote_port is Some(remote_port) else {
    write_json_error(conn, 400, "missing_field", "remote_port required")
    return
  }
  let remote_host_v = remote_host.unwrap_or("127.0.0.1")
  let rule = create_port_mapping_rule(
    peer_id, remote_protocol, remote_host_v, remote_port, local_host, local_port,
    note,
  ) catch {
    PortMappingError::DuplicatePort(p) => {
      write_json_error(
        conn,
        409,
        "port_in_use",
        "local port \{p} already claimed by another mapping",
      )
      return
    }
    PortMappingError::InvalidProtocol(p) => {
      write_json_error(
        conn,
        400,
        "invalid_protocol",
        "unsupported protocol: \{p}",
      )
      return
    }
    PortMappingError::InvalidPort(p) => {
      write_json_error(conn, 400, "invalid_port", "port out of range: \{p}")
      return
    }
    PortMappingError::AllocationFailed => {
      write_json_error(
        conn, 409, "allocation_failed", "could not find a free local port",
      )
      return
    }
    PortMappingError::NotFound(id) => {
      write_json_error(conn, 404, "not_found", "mapping \{id} not found")
      return
    }
    _ => {
      write_json_error(conn, 500, "internal_error", "create failed")
      return
    }
  }
  write_json_response(conn, 200, rule.to_json())
}

///|
async fn handle_port_mappings_delete(
  conn : @http.ServerConnection,
  id : String,
) -> Unit {
  delete_port_mapping_rule(id) catch {
    PortMappingError::NotFound(id) => {
      write_json_error(conn, 404, "not_found", "mapping \{id} not found")
      return
    }
    _ => {
      write_json_error(conn, 500, "internal_error", "delete failed")
      return
    }
  }
  write_json_response(conn, 200, { "removed": true })
}

///|
async fn handle_port_mappings_patch(
  conn : @http.ServerConnection,
  id : String,
  body_str : String,
) -> Unit {
  let obj = @json.parse(body_str) catch {
    _ => {
      write_json_error(conn, 400, "invalid_json", "request body must be JSON")
      return
    }
  }
  let enabled : Bool? = @jsonx.get(obj, "enabled")
  let note : String? = @jsonx.get(obj, "note")
  let rule = update_port_mapping_rule(id, enabled, note) catch {
    PortMappingError::NotFound(id) => {
      write_json_error(conn, 404, "not_found", "mapping \{id} not found")
      return
    }
    _ => {
      write_json_error(conn, 500, "internal_error", "update failed")
      return
    }
  }
  write_json_response(conn, 200, rule.to_json())
}
