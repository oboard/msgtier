///|
/// NetworkAddress represents a network endpoint (IP:port or hostname:port)
struct NetworkAddress {
  address : String
} derive(Show, ToJson, FromJson, Eq)

///|
/// Helper function to create a NetworkAddress
pub fn network_address(address : String) -> NetworkAddress {
  NetworkAddress::{ address, }
}
