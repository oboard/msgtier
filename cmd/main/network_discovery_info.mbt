///|
/// NetworkDiscoveryInfo represents information exchanged during network discovery
struct NetworkDiscoveryInfo {
  id : String
  version : String
  addresses : Array[NetworkAddress] // Multiple network addresses for this peer
  peers : Array[NetworkAddress]? // Known peer addresses
  public_key : Bytes // RSA public key for E2E encryption
} derive(Show, ToJson, FromJson)

///|
/// Helper function to create NetworkDiscoveryInfo
pub fn network_discovery_info(
  id : String,
  version : String,
  addresses : Array[NetworkAddress],
  peers? : Array[NetworkAddress],
  public_key : Bytes,
) -> NetworkDiscoveryInfo {
  NetworkDiscoveryInfo::{ id, version, addresses, peers, public_key }
}
