///|
/// NetworkAddress represents a network endpoint (IP:port or hostname:port)
struct NetworkAddress {
  address : String
} derive(Show, ToJson, FromJson, Eq)
