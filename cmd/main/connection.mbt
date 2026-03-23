///|
/// Connection represents a network connection to a peer
/// Each peer can have multiple connections (e.g., multiple network interfaces, redundant paths)
struct Connection {
  id : String
  peer_id : String
  last_seen : UInt64 // timestamp
  quality : Int // connection quality metric (0-100)
  relay : Int // 1 = direct, 2+ = relayed through N-1 peers
  metadata : Map[String, String]?
  latency_ms : Int? // Latest RTT in milliseconds (null if no pings yet)
  bandwidth_mbps : Double // Calculated bandwidth in Mbps
  packet_loss_rate : Int // Packet loss percentage (0-100)
  latency_history : Array[Int] // Recent RTT samples (last 20, approx 1 minute)
  packets_sent : Int // Total pings sent
  packets_lost : Int // Pings without pong response
  bytes_sent : UInt64 // Total bytes sent through connection
  bytes_received : UInt64 // Total bytes received
  last_ping_time : UInt64? // Timestamp when last ping was sent
  last_pong_time : UInt64? // Timestamp when last pong was received
  ports : Array[PortMapping] // Array of (local_port, protocol, remote_port) tuples
  ports_last_seen : Map[String, UInt64]
  version : String // Version of the peer
  nat_type : NatType
  address_stats : Map[String, AddressStats]
} derive(Show, ToJson, FromJson)

///|
struct AddressStats {
  last_ping_time : UInt64?
  last_pong_time : UInt64?
  packets_sent : Int
  packets_lost : Int
  packets_received : Int
  latency_ms : Int?
} derive(Show, ToJson, FromJson, Eq)

///|
struct PortMapping {
  src : Int
  protocol : Protocol
  dst : Int
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
fn Connection::new(my_id : String, peer_id : String) -> Connection {
  let (id1, id2) = if my_id < peer_id {
    (my_id, peer_id)
  } else {
    (peer_id, my_id)
  }
  let secret_hash = match app_state.config {
    Some(config) => bytes_to_hex(hash_secret(config.secret))
    None => bytes_to_hex(hash_secret(""))
  }
  let raw_id = "\{id1}:\{id2}:\{secret_hash}"
  let id = bytes_to_hex(Bytes::from_array(@crypto.sha256(@utf8.encode(raw_id))))

  {
    id,
    peer_id,
    last_seen: @env.now(),
    quality: 0,
    relay: 1,
    metadata: None,
    latency_ms: None,
    bandwidth_mbps: 0.0,
    packet_loss_rate: 0,
    latency_history: [],
    packets_sent: 0,
    packets_lost: 0,
    bytes_sent: 0UL,
    bytes_received: 0UL,
    last_ping_time: None,
    last_pong_time: None,
    ports: [],
    ports_last_seen: {},
    version: "",
    nat_type: Unknown,
    address_stats: {},
  }
}

///|
fn Connection::update_address_ping(
  self : Connection,
  addr : String,
  time : UInt64,
) -> Connection {
  let stats = self.address_stats
  let entry = match stats.get(addr) {
    Some(s) =>
      AddressStats::{
        ..s,
        last_ping_time: Some(time),
        packets_sent: s.packets_sent + 1,
      }
    None =>
      AddressStats::{
        last_ping_time: Some(time),
        last_pong_time: None,
        packets_sent: 1,
        packets_lost: 0,
        packets_received: 0,
        latency_ms: None,
      }
  }
  stats[addr] = entry
  { ..self, address_stats: stats }
}

///|
fn Connection::update_address_pong(
  self : Connection,
  addr : String,
  time : UInt64,
) -> Connection {
  let stats = self.address_stats
  let entry = match stats.get(addr) {
    Some(s) => {
      let latency = match s.last_ping_time {
        Some(ping_time) =>
          if time >= ping_time {
            Some((time - ping_time).to_int())
          } else {
            s.latency_ms
          }
        None => s.latency_ms
      }
      AddressStats::{
        ..s,
        last_pong_time: Some(time),
        latency_ms: latency,
        packets_received: s.packets_received + 1,
      }
    }
    None =>
      AddressStats::{
        last_ping_time: None,
        last_pong_time: Some(time),
        packets_sent: 0,
        packets_lost: 0,
        packets_received: 1,
        latency_ms: None,
      }
  }
  stats[addr] = entry
  { ..self, address_stats: stats }
}

///|
fn Connection::mark_address_packet_lost(
  self : Connection,
  addr : String,
) -> Connection {
  let stats = self.address_stats
  match stats.get(addr) {
    Some(s) => {
      let entry = AddressStats::{ ..s, packets_lost: s.packets_lost + 1 }
      stats[addr] = entry
      { ..self, address_stats: stats }
    }
    None => self
  }
}

///|
fn Connection::get_best_address(
  self : Connection,
  protocol : String,
) -> String? {
  let mut best_addr : String? = None
  let mut best_score = -1.0
  let now = @env.now()
  for addr, stats in self.address_stats {
    // Check protocol match (assuming addr is URL)
    if !addr.has_prefix(protocol + "://") {
      continue
    }

    // Must have received a pong recently (e.g., within 30s)
    let last_pong = stats.last_pong_time.unwrap_or(0UL)
    if now - last_pong > 30000UL {
      continue
    }

    // Calculate score: lower packet loss is better, lower latency is better
    // Score = 1000 - (loss_rate * 10) - latency_ms
    let loss_rate = if stats.packets_sent > 0 {
      let unacked = stats.packets_sent -
        stats.packets_lost -
        stats.packets_received
      let effective_loss = stats.packets_lost +
        (if unacked > 0 { unacked } else { 0 })
      effective_loss * 100 / stats.packets_sent
    } else {
      0
    }
    let latency = stats.latency_ms.unwrap_or(1000)
    let score = 1000.0 - loss_rate.to_double() * 10.0 - latency.to_double()
    if score > best_score {
      best_score = score
      best_addr = Some(addr)
    }
  }
  best_addr
}

///|
fn extract_host(addr : String) -> String {
  let normalized = if addr.contains("://") { addr } else { "tcp://" + addr }
  let parsed = try? Address::parse(normalized)
  match parsed {
    Ok(value) => value.host
    Err(_) => addr
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
      if parse_int_simple(parts[1].to_string()) is Some(v) {
        return v >= 16 && v <= 31
      }
      return false
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
  Some(@strconv.parse_int(s)) catch {
    _ => None
  }
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

///|
fn Connection::update_last_pong_time(
  self : Connection,
  time : UInt64?,
) -> Connection {
  { ..self, last_pong_time: time }
}

///|
fn make_port_key(
  local_port : Int,
  protocol : Protocol,
  remote_port : Int,
) -> String {
  local_port.to_string() +
  "|" +
  protocol.to_string() +
  "|" +
  remote_port.to_string()
}

///|
fn Connection::touch_port(
  self : Connection,
  local_port : Int,
  protocol : Protocol,
  remote_port : Int,
  time : UInt64,
) -> Connection {
  let ports = self.ports.copy()
  let mut exists = false
  for p in ports {
    if p.src == local_port && p.protocol == protocol && p.dst == remote_port {
      exists = true
      break
    }
  }
  if !exists {
    ports.push(PortMapping::{ src: local_port, protocol, dst: remote_port })
  }
  let ports_last_seen = self.ports_last_seen
  let key = make_port_key(local_port, protocol, remote_port)
  ports_last_seen[key] = time
  { ..self, ports, ports_last_seen }
}

///|
fn Connection::prune_ports(
  self : Connection,
  now : UInt64,
  timeout_ms : UInt64,
) -> Connection {
  let new_ports : Array[PortMapping] = []
  let new_ports_last_seen : Map[String, UInt64] = {}
  for p in self.ports {
    let key = make_port_key(p.src, p.protocol, p.dst)
    match self.ports_last_seen.get(key) {
      Some(ts) =>
        if now >= ts && now - ts <= timeout_ms {
          new_ports.push(p)
          new_ports_last_seen[key] = ts
        }
      None => new_ports.push(p)
    }
  }
  { ..self, ports: new_ports, ports_last_seen: new_ports_last_seen }
}

///|
fn Connection::to_msgpack(self : Connection) -> @msgpack.Value {
  let ports_val = @msgpack.array(
    self.ports.map(fn(p) {
      @msgpack.array([
        @msgpack.int(p.src),
        @msgpack.string(p.protocol.to_string()),
        @msgpack.int(p.dst),
      ])
    }),
  )
  @msgpack.array([
    @msgpack.string(self.peer_id),
    @msgpack.nil(),
    @msgpack.int(self.relay),
    match self.latency_ms {
      Some(l) => @msgpack.int(l)
      None => @msgpack.nil()
    },
    @msgpack.float64(self.bandwidth_mbps),
    @msgpack.int(self.packet_loss_rate),
    @msgpack.string(self.id),
    @msgpack.nil(),
    ports_val,
    @msgpack.uint64(self.last_seen),
    @msgpack.int(self.quality),
    match self.metadata {
      Some(m) => {
        let map_val = {}
        for k, v in m {
          map_val[k] = @msgpack.string(v)
        }
        @msgpack.map(map_val)
      }
      None => @msgpack.nil()
    },
    @msgpack.array(self.latency_history.map(@msgpack.int)),
    @msgpack.int(self.packets_sent),
    @msgpack.int(self.packets_lost),
    @msgpack.uint64(self.bytes_sent),
    @msgpack.uint64(self.bytes_received),
    match self.last_ping_time {
      Some(t) => @msgpack.uint64(t)
      None => @msgpack.nil()
    },
    @msgpack.string(self.version),
    @msgpack.string(self.nat_type.to_string()),
    {
      let m = {}
      for k, v in self.address_stats {
        m[k] = @msgpack.array([
          match v.last_ping_time {
            Some(t) => @msgpack.uint64(t)
            None => @msgpack.nil()
          },
          match v.last_pong_time {
            Some(t) => @msgpack.uint64(t)
            None => @msgpack.nil()
          },
          @msgpack.int(v.packets_sent),
          @msgpack.int(v.packets_lost),
          match v.latency_ms {
            Some(l) => @msgpack.int(l)
            None => @msgpack.nil()
          },
          @msgpack.int(v.packets_received),
        ])
      }
      @msgpack.map(m)
    },
  ])
}

///|
fn Connection::from_msgpack(msgpack : @msgpack.Value) -> Connection? {
  match msgpack {
    Array(
      [
        String(peer_id),
        _,
        Int(relay),
        latency_val,
        Float64(bandwidth_mbps),
        Int(packet_loss_rate),
        String(id),
        _,
        protocol_val,
        UInt64(last_seen),
        Int(quality),
        metadata_val,
        Array(latency_history_val),
        Int(packets_sent),
        Int(packets_lost),
        UInt64(bytes_sent),
        UInt64(bytes_received),
        last_ping_time_val,
        String(version),
        String(nat_type_str),
        address_stats_val,
      ]
    ) => {
      let nat_type = match nat_type_str {
        "NoNAT" => NoNAT
        "Symmetric" => Symmetric
        "FullCone" => FullCone
        "Restricted" => Restricted
        "PortRestricted" => PortRestricted
        "Unknown" => Unknown
        _ => Unknown
      }
      let latency_ms = match latency_val {
        Int(l) => Some(l)
        _ => None
      }
      let _ = match protocol_val {
        String(_) => ()
        Nil => ()
        _ => ()
      }
      let metadata = match metadata_val {
        Map(m) => {
          let map = {}
          for k, v in m {
            match v {
              String(vs) => map[k] = vs
              _ => ()
            }
          }
          Some(map)
        }
        _ => None
      }
      let latency_history = latency_history_val.map(fn(v) {
        match v {
          Int(i) => i
          _ => 0
        }
      })
      let last_ping_time = match last_ping_time_val {
        UInt64(t) => Some(t)
        _ => None
      }
      let address_stats = match address_stats_val {
        Map(m) => {
          let stats = {}
          for k, v in m {
            match v {
              Array(arr) =>
                if arr.length() >= 5 {
                  let ping_val = arr[0]
                  let pong_val = arr[1]
                  let sent = match arr[2] {
                    Int(i) => i
                    _ => 0
                  }
                  let lost = match arr[3] {
                    Int(i) => i
                    _ => 0
                  }
                  let latency_val = arr[4]
                  let received = if arr.length() >= 6 {
                    match arr[5] {
                      Int(i) => i
                      _ => 0
                    }
                  } else {
                    0
                  }
                  let last_ping_time = match ping_val {
                    UInt64(t) => Some(t)
                    _ => None
                  }
                  let last_pong_time = match pong_val {
                    UInt64(t) => Some(t)
                    _ => None
                  }
                  let latency_ms = match latency_val {
                    Int(l) => Some(l)
                    _ => None
                  }
                  stats[k] = AddressStats::{
                    last_ping_time,
                    last_pong_time,
                    packets_sent: sent,
                    packets_lost: lost,
                    packets_received: received,
                    latency_ms,
                  }
                }
              _ => ()
            }
          }
          stats
        }
        _ => {}
      }
      let ports = match protocol_val {
        Array(port_entries) => {
          let parsed : Array[PortMapping] = []
          for entry in port_entries {
            match entry {
              Array([Int(local_port), String(protocol), Int(remote_port)]) =>
                match Protocol::parse(protocol[:]) {
                  Some(proto) =>
                    parsed.push(PortMapping::{
                      src: local_port,
                      protocol: proto,
                      dst: remote_port,
                    })
                  None => ()
                }
              Array([Int(local_port), String(protocol), UInt64(remote_port)]) =>
                match Protocol::parse(protocol[:]) {
                  Some(proto) =>
                    parsed.push(PortMapping::{
                      src: local_port,
                      protocol: proto,
                      dst: remote_port.to_int(),
                    })
                  None => ()
                }
              Array([UInt64(local_port), String(protocol), Int(remote_port)]) =>
                match Protocol::parse(protocol[:]) {
                  Some(proto) =>
                    parsed.push(PortMapping::{
                      src: local_port.to_int(),
                      protocol: proto,
                      dst: remote_port,
                    })
                  None => ()
                }
              Array([UInt64(local_port), String(protocol), UInt64(remote_port)]) =>
                match Protocol::parse(protocol[:]) {
                  Some(proto) =>
                    parsed.push(PortMapping::{
                      src: local_port.to_int(),
                      protocol: proto,
                      dst: remote_port.to_int(),
                    })
                  None => ()
                }
              _ => ()
            }
          }
          parsed
        }
        _ => []
      }
      Some(Connection::{
        peer_id,
        relay,
        latency_ms,
        bandwidth_mbps,
        packet_loss_rate,
        id,
        last_seen,
        quality,
        metadata,
        latency_history,
        packets_sent,
        packets_lost,
        bytes_sent,
        bytes_received,
        last_ping_time,
        last_pong_time: None,
        ports,
        ports_last_seen: {},
        version,
        nat_type,
        address_stats,
      })
    }
    _ => None
  }
}
