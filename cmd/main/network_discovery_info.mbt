///|
/// NetworkDiscoveryInfo represents information exchanged during network discovery
struct NetworkDiscoveryInfo {
  id : String
  version : String
  addresses : Array[NetworkAddress] // Multiple network addresses for this peer
  peers : Array[NetworkAddress]? // Known peer addresses
} derive(Show, ToJson, FromJson)
