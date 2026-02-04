///|
struct RouteInfo {
  target_peer_id : String
  next_hop : String
  hops : Int
  timestamp : UInt64
} derive(ToJson)
