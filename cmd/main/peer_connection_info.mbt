///|
struct PeerConnectionInfo {
  id : String
  peer_id : String
  last_seen : UInt64
  quality : Int
  relay : Int
  ports : Array[PortMapping]
  metadata : Map[String, String]?
  latency_ms : Int?
  latency_history : Array[Int]
  packets_sent : Int
  packets_lost : Int
  bytes_sent : UInt64
  bytes_received : UInt64
  last_ping_time : UInt64?
  bandwidth_mbps : Double
  packet_loss_rate : Int
  nat_type : NatType
} derive(Show)

///|
fn peer_conn_metadata_to_json_map(
  metadata : Map[String, String],
) -> Map[String, Json] {
  let result : Map[String, Json] = {}
  for key, value in metadata {
    if key == "scripts" {
      result[key] = @json.parse(value) catch { _ => value.to_json() }
    } else {
      result[key] = value.to_json()
    }
  }
  result
}

///|
impl ToJson for PeerConnectionInfo with to_json(self) {
  {
    "id": self.id,
    "peer_id": self.peer_id,
    "last_seen": self.last_seen,
    "quality": self.quality,
    "relay": self.relay,
    "ports": self.ports,
    "metadata": self.metadata.map(fn(m) { peer_conn_metadata_to_json_map(m) }),
    "latency_ms": self.latency_ms,
    "latency_history": self.latency_history,
    "packets_sent": self.packets_sent,
    "packets_lost": self.packets_lost,
    "bytes_sent": self.bytes_sent,
    "bytes_received": self.bytes_received,
    "last_ping_time": self.last_ping_time,
    "bandwidth_mbps": self.bandwidth_mbps,
    "packet_loss_rate": self.packet_loss_rate,
    "nat_type": self.nat_type,
  }
}
