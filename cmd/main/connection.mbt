///|
/// Connection represents a network connection to a peer
/// Each peer can have multiple connections (e.g., multiple network interfaces, redundant paths)
struct Connection {
  id : String
  local_addr : String
  remote_addr : String
  protocol : String // "tcp", "udp", etc.
  peer_id : String
  last_seen : UInt64 // timestamp
  quality : Int // connection quality metric (0-100)
  relay : Int // 1 = direct, 2+ = relayed through N-1 peers
  metadata : Map[String, String]?
  latency_ms : Int? // Latest RTT in milliseconds (null if no pings yet)
  latency_history : Array[Int] // Recent RTT samples (last 20, approx 1 minute)
  packets_sent : Int // Total pings sent
  packets_lost : Int // Pings without pong response
  bytes_sent : UInt64 // Total bytes sent through connection
  bytes_received : UInt64 // Total bytes received
  last_ping_time : UInt64? // Timestamp when last ping was sent
  nat_type : NatType
  session_id : String? // Unique session ID for the connection
} derive(Show, ToJson, FromJson)

///|
enum NatType {
  NoNAT
  Symmetric
  FullCone
  Restricted
  PortRestricted
  Unknown
} derive(Show, ToJson, FromJson, Eq)

///|

///|
fn Connection::new(
  my_id : String,
  peer_id : String,
  local_addr : String,
  remote_addr : String,
  protocol : String,
  session_id? : String,
) -> Connection {
  let (id1, id2) = if my_id < peer_id {
    (my_id, peer_id)
  } else {
    (peer_id, my_id)
  }
  let normalized_session = match session_id {
    Some(sid) => if sid.is_empty() { None } else { Some(sid) }
    None => None
  }
  let id = match normalized_session {
    Some(sid) => sid
    None => {
      let raw_id = "\{id1}:\{id2}:\{protocol}"
      bytes_to_hex(Bytes::from_array(@crypto.sha256(@utf8.encode(raw_id))))
    }
  }

  // Analyze NAT type based on address characteristics
  // This is a preliminary analysis; accurate determination requires STUN/discovery
  let nat_type = analyze_nat_type(local_addr, remote_addr)
  {
    id,
    local_addr,
    remote_addr,
    protocol,
    peer_id,
    last_seen: @env.now(),
    quality: 0,
    relay: 1,
    metadata: None,
    latency_ms: None,
    latency_history: [],
    packets_sent: 0,
    packets_lost: 0,
    bytes_sent: 0UL,
    bytes_received: 0UL,
    last_ping_time: None,
    nat_type,
    session_id: normalized_session,
  }
}

///|
fn analyze_nat_type(local_addr : String, remote_addr : String) -> NatType {
  let local_ip = extract_host(local_addr)
  let remote_ip = extract_host(remote_addr)
  if is_loopback(local_ip) && is_loopback(remote_ip) {
    return NoNAT
  }

  // If local is public, we are not behind NAT (direct connection)
  if !is_private(local_ip) && !is_loopback(local_ip) {
    return NoNAT
  }
  if is_private(local_ip) {
    // Local Private, Remote Public -> Behind NAT
    if !is_private(remote_ip) && !is_loopback(remote_ip) {
      return PortRestricted // Assume typical NAT behavior
    }

    // Both private
    if is_private(remote_ip) {
      if is_same_subnet(local_ip, remote_ip) {
        return NoNAT // Same LAN
      } else {
        return Symmetric // Different private networks, likely complex NAT/Routing
      }
    }
  }
  Unknown
}

///|
fn extract_host(addr : String) -> String {
  let s = if addr.contains("://") {
    let parts = addr.split("://").to_array()
    if parts.length() > 1 {
      parts[1].to_string()
    } else {
      addr
    }
  } else {
    addr
  }
  if s.has_prefix("[") {
    let mut end_idx = -1
    let mut i = 0
    for c in s {
      if c == ']' {
        end_idx = i
        break
      }
      i = i + 1
    }
    if end_idx != -1 {
      s[1:end_idx].to_string() catch {
        _ => s
      }
    } else {
      s
    }
  } else {
    let mut colons = 0
    for c in s {
      if c == ':' {
        colons = colons + 1
      }
    }
    if colons > 1 {
      s // IPv6 without brackets
    } else if colons == 1 {
      let parts = s.split(":").to_array()
      parts[0].to_string()
    } else {
      s
    }
  }
}

///|
fn is_loopback(ip : String) -> Bool {
  ip == "localhost" ||
  ip.has_prefix("127.") ||
  ip == "::1" ||
  ip == "0:0:0:0:0:0:0:1"
}

///|
fn is_private(ip : String) -> Bool {
  if ip.has_prefix("10.") {
    return true
  }
  if ip.has_prefix("192.168.") {
    return true
  }
  if ip.has_prefix("172.") {
    let parts = ip.split(".").to_array()
    if parts.length() > 1 {
      match parse_int_simple(parts[1].to_string()) {
        Some(v) => return v >= 16 && v <= 31
        None => return false
      }
    }
  }
  // IPv6 ULA (Unique Local Address) fc00::/7
  if ip.has_prefix("fc") || ip.has_prefix("fd") {
    return true
  }
  false
}

///|
fn parse_int_simple(s : String) -> Int? {
  let mut res = 0
  for c in s {
    if c < '0' || c > '9' {
      return None
    }
    res = res * 10 + (c.to_int() - '0'.to_int())
  }
  Some(res)
}

///|
fn is_same_subnet(ip1 : String, ip2 : String) -> Bool {
  // Check /24 for IPv4
  let p1 = ip1.split(".").to_array()
  let p2 = ip2.split(".").to_array()
  if p1.length() == 4 && p2.length() == 4 {
    return p1[0] == p2[0] && p1[1] == p2[1] && p1[2] == p2[2]
  }
  false
}

///|
fn Connection::update_relay(self : Connection, relay_depth : Int) -> Connection {
  { ..self, relay: relay_depth }
}

///|
///  // This function is used for connection health monitoring
fn Connection::update_last_seen(
  self : Connection,
  timestamp : UInt64,
) -> Connection {
  { ..self, last_seen: timestamp }
}

///|
fn Connection::calculate_packet_loss(self : Connection) -> Int {
  if self.packets_sent == 0 {
    0
  } else {
    self.packets_lost * 100 / self.packets_sent
  }
}

///|
fn Connection::calculate_bandwidth_mbps(
  self : Connection,
  elapsed_ms : UInt64,
) -> Double {
  if elapsed_ms == 0UL {
    0.0
  } else {
    let bytes_in_mb = self.bytes_received.reinterpret_as_int64().to_double() /
      1_000_000.0
    let seconds = elapsed_ms.reinterpret_as_int64().to_double() / 1000.0
    bytes_in_mb / seconds
  }
}

///|
fn Connection::update_last_ping_time(
  self : Connection,
  time : UInt64?,
) -> Connection {
  { ..self, last_ping_time: time }
}
