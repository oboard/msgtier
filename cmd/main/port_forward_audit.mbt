///|
struct PortForwardAuditEntry {
  rule_id : String
  protocol : String
  requester_peer_id : String
  expose_peer_id : String
  target : String
  started_at : UInt64
  mut ended_at : UInt64?
  mut bytes_in : Int
  mut bytes_out : Int
  mut status : String
}

///|
fn record_port_forward_audit_open(
  rule_id : String,
  protocol : String,
  requester_peer_id : String,
  expose_peer_id : String,
  target : String,
) -> PortForwardAuditEntry {
  let entry = {
    rule_id,
    protocol,
    requester_peer_id,
    expose_peer_id,
    target,
    started_at: @env.now(),
    ended_at: None,
    bytes_in: 0,
    bytes_out: 0,
    status: "open",
  }
  log_info(
    "port_forward open rule=\{rule_id} protocol=\{protocol} requester=\{requester_peer_id} expose=\{expose_peer_id} target=\{target}",
  )
  entry
}

///|
fn record_port_forward_audit_close(
  audit : PortForwardAuditEntry,
  status : String,
) -> Unit {
  audit.ended_at = Some(@env.now())
  audit.status = status
  log_info(
    "port_forward close rule=\{audit.rule_id} protocol=\{audit.protocol} requester=\{audit.requester_peer_id} expose=\{audit.expose_peer_id} bytes_in=\{audit.bytes_in} bytes_out=\{audit.bytes_out} status=\{status}",
  )
}
