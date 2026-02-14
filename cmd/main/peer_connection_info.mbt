///|
struct PeerConnectionInfo {
  id : String
  peer_id : String
  last_seen : UInt64
  quality : Int
  relay : Int
  protocol : String
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
} derive(Show, ToJson)
