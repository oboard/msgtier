///|
/// NetworkAddress represents a network endpoint (IP:port or hostname:port)
struct NetworkAddress {
  address : String
} derive(Debug, ToJson, FromJson, Eq)

///|
pub impl Show for NetworkAddress with fn output(self, logger) {
  logger.write_string(self.address)
}
