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
  mut buffered_bytes : Int
  mut buffered_chunks : Int
  // The reader task also owns the open/ack handshake.
  mut reader : @async.Task[Unit]?
  mut writer : @async.Task[Unit]?
  mut close_timer : @async.Task[Unit]?
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
priv struct PortForwardTcpPendingOpen {
  mut task : @async.Task[Unit]?
  mut closed : Bool
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
  tcp_forward_servers : Map[String, @socket.TcpServer]
  tcp_forward_connections : Map[String, PortForwardTcpEndpoint]
  tcp_expose_connections : Map[String, PortForwardTcpEndpoint]
  tcp_expose_pending_opens : Map[String, PortForwardTcpPendingOpen]
  udp_forward_runtimes : Map[String, PortForwardUdpForwardRuntime]
  udp_forward_session_by_id : Map[String, PortForwardUdpForwardSession]
  udp_forward_session_by_source : Map[String, String]
  udp_expose_sessions : Map[String, PortForwardUdpExposeSession]
}

///|
let port_forward_registry_state : PortForwardRegistryState = {
  initialized: false,
  tcp_forward_started: Map([]),
  tcp_forward_servers: Map([]),
  tcp_forward_connections: Map([]),
  tcp_expose_connections: Map([]),
  tcp_expose_pending_opens: Map([]),
  udp_forward_runtimes: Map([]),
  udp_forward_session_by_id: Map([]),
  udp_forward_session_by_source: Map([]),
  udp_expose_sessions: Map([]),
}

///|
fn get_port_forward_metadata_json() -> String {
  let items : Array[Json] = []
  for rule in get_port_forward_active_forward_rules() {
    let rule_key = make_port_forward_forward_rule_key(rule)
    let state = if !is_port_forward_rule_enabled(rule.enabled) {
      "disabled"
    } else if is_port_forward_tcp_protocol(rule.protocol) &&
      port_forward_registry_state.tcp_forward_started.contains(rule_key) {
      "listening"
    } else if port_forward_transport(rule.protocol) == "udp" &&
      port_forward_registry_state.udp_forward_runtimes.contains(rule_key) {
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
fn forget_port_forward_tcp_endpoint(endpoint : PortForwardTcpEndpoint) -> Unit {
  let connection_id = endpoint.connection_id
  if get_port_forward_tcp_forward_connection(connection_id) is Some(current) &&
    physical_equal(current, endpoint) {
    port_forward_registry_state.tcp_forward_connections.remove(connection_id)
  }
  if get_port_forward_tcp_expose_connection(connection_id) is Some(current) &&
    physical_equal(current, endpoint) {
    port_forward_registry_state.tcp_expose_connections.remove(connection_id)
  }
}

///|
fn forget_port_forward_tcp_pending_open(
  connection_id : String,
  pending : PortForwardTcpPendingOpen,
) -> Unit {
  if port_forward_registry_state.tcp_expose_pending_opens.get(connection_id)
    is Some(current) &&
    physical_equal(current, pending) {
    port_forward_registry_state.tcp_expose_pending_opens.remove(connection_id)
  }
}

///|
fn cancel_port_forward_tcp_pending_open(connection_id : String) -> Unit {
  if port_forward_registry_state.tcp_expose_pending_opens.get(connection_id)
    is Some(pending) {
    pending.closed = true
    forget_port_forward_tcp_pending_open(connection_id, pending)
    if pending.task is Some(task) {
      pending.task = None
      task.cancel()
    }
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
