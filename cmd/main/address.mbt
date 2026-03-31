///|
/// Protocol represents the network transport protocol
pub enum Protocol {
  Tcp
  Udp
  Ws
  Wss
  Quic
} derive(Show, Eq, Hash)

///|
/// Convert protocol to its string representation
pub fn Protocol::to_string(self : Protocol) -> String {
  match self {
    Tcp => "tcp"
    Udp => "udp"
    Ws => "ws"
    Wss => "wss"
    Quic => "quic"
  }
}

///|
/// Parse protocol from string
pub fn Protocol::parse(s : StringView) -> Protocol? {
  match s {
    "tcp" => Some(Tcp)
    "udp" => Some(Udp)
    "ws" => Some(Ws)
    "wss" => Some(Wss)
    "quic" => Some(Quic)
    _ => None
  }
}

///|
/// Address represents a fully-typed network endpoint with protocol, host, and port.
/// This is the unified address type that replaces the inconsistent mix of String,
/// @socket.Addr, @url.Url, and NetworkAddress throughout the codebase.
pub struct Address {
  protocol : Protocol
  host : String // IPv4, IPv6 (without brackets), or hostname
  port : UInt16
} derive(Show, Eq, Hash)

///|
suberror AddressParseError {
  MissingProtocol
  InvalidProtocol(String)
  MissingHost
  MissingPort
  InvalidPort(String)
  InvalidFormat(String)
} derive(Show)

///|
/// Create a new Address with the given components
pub fn Address::new(
  protocol : Protocol,
  host : String,
  port : UInt16,
) -> Address {
  { protocol, host, port }
}

///|
/// Parse an address from a URL string like "tcp://127.0.0.1:9000"
pub fn Address::parse(input : String) -> Address raise {
  let protocol_str = lexmatch input[:] with longest {
    (("[^:]+" as protocol) "://", _) => protocol.to_string()
    _ => raise AddressParseError::MissingProtocol
  }
  guard Protocol::parse(protocol_str[:]) is Some(protocol) else {
    raise AddressParseError::InvalidProtocol(protocol_str)
  }
  guard @url.Url::parse(input) is Some(url) else {
    raise AddressParseError::InvalidFormat(input)
  }
  let host = match url.hostname() {
    "" => raise AddressParseError::MissingHost
    h =>
      if h.has_prefix("[") && h.has_suffix("]") {
        h[1:h.length() - 1].to_string()
      } else {
        h
      }
  }
  let port_str = match url.get_port() {
    "" =>
      match protocol {
        Ws => "80"
        Wss => "443"
        _ => raise AddressParseError::MissingPort
      }
    p => p
  }
  let port = parse_port(port_str) catch {
    _ => raise AddressParseError::InvalidPort(port_str)
  }
  { protocol, host, port }
}

///|
/// Returns the socket-compatible string "host:port" (no protocol)
pub fn Address::to_socket_string(self : Address) -> String {
  // Handle IPv6 addresses (need brackets)
  if self.host.contains(":") {
    "[" + self.host + "]:" + self.port.to_string()
  } else {
    self.host + ":" + self.port.to_string()
  }
}

///|
/// Returns the full URL string "protocol://host:port"
pub fn Address::to_url_string(self : Address) -> String {
  self.protocol.to_string() + "://" + self.to_socket_string()
}

///|
/// Get a parsed @socket.Addr for this address
/// Note: This parses on each call; for high-frequency use, consider caching externally
pub fn Address::socket_addr(self : Address) -> @socket.Addr raise {
  @socket.Addr::parse(self.to_socket_string())
}

///|
/// Parse port number from string
fn parse_port(s : String) -> UInt16 raise {
  guard s != "" else { fail("empty port") }
  let is_decimal = lexmatch s[:] with longest {
    "[0-9]+" => true
    _ => false
  }
  guard is_decimal else { fail("invalid digit") }
  let port = @string.parse_int(s) catch { _ => fail("invalid digit") }
  guard port <= 65535 else { fail("port out of range") }
  port.to_uint16()
}

///|
pub impl ToJson for Address with to_json(self) {
  self.to_url_string().to_json()
}

///|
pub impl @json.FromJson for Address with from_json(json, path) {
  match json {
    String(s) => {
      let addr = Address::parse(s) catch {
        e => raise @json.JsonDecodeError((path, "Invalid address: \{e}"))
      }
      addr
    }
    _ => raise @json.JsonDecodeError((path, "Expected string for Address"))
  }
}

///|
pub impl ToJson for Protocol with to_json(self) {
  self.to_string().to_json()
}

///|
pub impl @json.FromJson for Protocol with from_json(json, path) {
  match json {
    String(s) =>
      match Protocol::parse(s[:]) {
        Some(p) => p
        None => raise @json.JsonDecodeError((path, "Invalid protocol: " + s))
      }
    _ => raise @json.JsonDecodeError((path, "Expected string for Protocol"))
  }
}
