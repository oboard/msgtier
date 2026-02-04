///|
struct StatusInfo {
  peer_id : String
  status : String
  listeners : Array[String]
  known_peers : Array[String]
  peers : Array[PeerNode]
  peers_count : Int
  routes : Array[RouteInfo]
} derive(ToJson)
