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
  let input_view = input[:]

  // Find "://" separator
  let mut protocol_end = -1
  let mut i = 0
  for c in input_view {
    if c == ':' && i + 2 < input.length() {
      let next2 = input[i + 1:i + 3]
      if next2 == "//" {
        protocol_end = i
        break
      }
    }
    i = i + 1
  }
  if protocol_end <= 0 {
    raise AddressParseError::MissingProtocol
  }
  let protocol_str = input[0:protocol_end]
  let protocol = match Protocol::parse(protocol_str[:]) {
    Some(p) => p
    None => raise AddressParseError::InvalidProtocol(protocol_str.to_string())
  }

  // Skip past "://"
  let host_start = protocol_end + 3
  if host_start >= input.length() {
    raise AddressParseError::MissingHost
  }
  let rest = input[host_start:]

  // Parse host and port
  // Handle IPv6 addresses in brackets: [::1]:port
  let (host, port_str) = if rest.has_prefix("[") {
    // IPv6 address - find closing bracket
    let mut bracket_end = -1
    let mut j = 0
    for c in rest {
      if c == ']' {
        bracket_end = j
        break
      }
      j = j + 1
    }
    if bracket_end == -1 {
      raise AddressParseError::InvalidFormat("Unclosed IPv6 bracket")
    }
    let ipv6_host = rest[1:bracket_end].to_string()
    let after_bracket = rest[bracket_end + 1:]
    if after_bracket.has_prefix(":") {
      (ipv6_host, after_bracket[1:].to_string())
    } else {
      raise AddressParseError::MissingPort
    }
  } else {
    // IPv4 or hostname - find last colon
    let mut last_colon = -1
    let mut k = 0
    for c in rest {
      if c == ':' {
        last_colon = k
      }
      k = k + 1
    }
    if last_colon == -1 {
      raise AddressParseError::MissingPort
    }
    (rest[0:last_colon].to_string(), rest[last_colon + 1:].to_string())
  }
  if host.is_empty() {
    raise AddressParseError::MissingHost
  }

  // Parse port number
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
  if s.is_empty() {
    fail("empty port")
  }
  let mut result = 0
  for c in s {
    if c < '0' || c > '9' {
      fail("invalid digit")
    }
    result = result * 10 + (c.to_int() - '0'.to_int())
    if result > 65535 {
      fail("port out of range")
    }
  }
  result.to_uint16()
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
