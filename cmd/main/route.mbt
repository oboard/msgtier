///|
struct Route {
  next_hop : String // Peer ID of the next hop
  hops : Int // Distance (number of hops)
  timestamp : UInt64 // When this route was learned
} derive(Show, ToJson, FromJson)
