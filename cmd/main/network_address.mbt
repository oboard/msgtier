///|
/// NetworkAddress represents a network endpoint (IP:port or hostname:port)
struct NetworkAddress {
  address : String
} derive(Debug, ToJson, FromJson, Eq)

///|
pub impl Show for NetworkAddress with output(self, logger) {
  logger.write_string(self.address)
}
