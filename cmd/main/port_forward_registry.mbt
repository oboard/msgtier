///|
struct PortForwardTcpEndpoint {
  socket : @socket.Tcp
  send_seq : Ref[Int]
  recv_next_seq : Ref[Int]
  remote_close_seq : Ref[Int?]
  recv_buffer : Ref[Map[Int, Bytes]]
  pending_writes : Ref[Array[Bytes]]
  draining : Ref[Bool]
  closed : Ref[Bool]
  cond : @cond_var.Cond
  rule_id : String
  peer_id : String
  protocol : String
  connection_id : String
  mut route_protocol : String
  mut route_addr : String
  mut opened : Bool
  mut failed : Bool
  mut error : String?
  audit : PortForwardAuditEntry
}

///|
struct PortForwardUdpForwardRuntime {
  rule : PortForwardForwardRule
  server : @socket.UdpServer
}

///|
struct PortForwardUdpForwardSession {
  rule_key : String
  source_addr : String
  route_protocol : String
  route_addr : String
  mut last_seen : UInt64
}

///|
struct PortForwardUdpExposeSession {
  peer_id : String
  route_protocol : String
  route_addr : String
  client : @socket.UdpClient
  mut last_seen : UInt64
  audit : PortForwardAuditEntry
}

///|
struct PortForwardRegistryState {
  mut initialized : Bool
  tcp_forward_started : Map[String, Bool]
  udp_forward_started : Map[String, Bool]
  tcp_forward_connections : Map[String, PortForwardTcpEndpoint]
  tcp_expose_connections : Map[String, PortForwardTcpEndpoint]
  udp_forward_runtimes : Map[String, PortForwardUdpForwardRuntime]
  udp_forward_session_by_id : Map[String, PortForwardUdpForwardSession]
  udp_forward_session_by_source : Map[String, String]
  udp_expose_sessions : Map[String, PortForwardUdpExposeSession]
}

///|
let port_forward_registry_state : PortForwardRegistryState = {
  initialized: false,
  tcp_forward_started: {},
  udp_forward_started: {},
  tcp_forward_connections: {},
  tcp_expose_connections: {},
  udp_forward_runtimes: {},
  udp_forward_session_by_id: {},
  udp_forward_session_by_source: {},
  udp_expose_sessions: {},
}

///|
fn get_port_forward_metadata_json() -> String {
  let items : Array[Json] = []
  for rule in get_port_forward_expose_rules() {
    items.push({
      "id": rule.id,
      "protocol": rule.protocol,
      "direction": "expose",
      "state": if is_port_forward_rule_enabled(rule.enabled) {
        "configured"
      } else {
        "disabled"
      },
    })
  }
  for rule in get_port_forward_forward_rules() {
    let rule_key = make_port_forward_forward_rule_key(rule)
    let state = if !is_port_forward_rule_enabled(rule.enabled) {
      "disabled"
    } else if rule.protocol == "tcp" &&
      port_forward_registry_state.tcp_forward_started.contains(rule_key) {
      "listening"
    } else if rule.protocol == "udp" &&
      port_forward_registry_state.udp_forward_started.contains(rule_key) {
      "listening"
    } else if get_global_peer_manager().get_peer(rule.peer_id) is Some(_) {
      "configured"
    } else {
      "peer_unavailable"
    }
    items.push({
      "id": rule.id,
      "protocol": rule.protocol,
      "direction": "forward",
      "peer_id": rule.peer_id,
      "listen_host": rule.listen_host,
      "listen_port": rule.listen_port,
      "state": state,
    })
  }
  items.to_json().stringify()
}

///|
fn get_port_forward_tcp_forward_connection(
  connection_id : String,
) -> PortForwardTcpEndpoint? {
  port_forward_registry_state.tcp_forward_connections.get(connection_id)
}

///|
fn get_port_forward_tcp_expose_connection(
  connection_id : String,
) -> PortForwardTcpEndpoint? {
  port_forward_registry_state.tcp_expose_connections.get(connection_id)
}

///|
fn remove_port_forward_tcp_forward_connection(
  connection_id : String,
) -> PortForwardTcpEndpoint? {
  let conn = port_forward_registry_state.tcp_forward_connections.get(
    connection_id,
  )
  match conn {
    Some(value) => {
      port_forward_registry_state.tcp_forward_connections.remove(connection_id)
      Some(value)
    }
    None => None
  }
}

///|
fn remove_port_forward_tcp_expose_connection(
  connection_id : String,
) -> PortForwardTcpEndpoint? {
  let conn = port_forward_registry_state.tcp_expose_connections.get(
    connection_id,
  )
  match conn {
    Some(value) => {
      port_forward_registry_state.tcp_expose_connections.remove(connection_id)
      Some(value)
    }
    None => None
  }
}

///|
fn touch_port_forward_udp_forward_session(session_id : String) -> Unit {
  match port_forward_registry_state.udp_forward_session_by_id.get(session_id) {
    Some(session) => session.last_seen = @env.now()
    None => ()
  }
}

///|
fn touch_port_forward_udp_expose_session(session_id : String) -> Unit {
  match port_forward_registry_state.udp_expose_sessions.get(session_id) {
    Some(session) => session.last_seen = @env.now()
    None => ()
  }
}
