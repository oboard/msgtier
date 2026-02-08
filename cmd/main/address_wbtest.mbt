///|
test "Address::parse basic IPv4 TCP" {
  let addr = Address::parse("tcp://127.0.0.1:9000")
  inspect(addr.protocol, content="Tcp")
  inspect(addr.host, content="127.0.0.1")
  inspect(addr.port, content="9000")
}

///|
test "Address::parse basic IPv4 UDP" {
  let addr = Address::parse("udp://192.168.1.1:8080")
  inspect(addr.protocol, content="Udp")
  inspect(addr.host, content="192.168.1.1")
  inspect(addr.port, content="8080")
}

///|
test "Address::parse WebSocket" {
  let addr = Address::parse("ws://localhost:3000")
  inspect(addr.protocol, content="Ws")
  inspect(addr.host, content="localhost")
  inspect(addr.port, content="3000")
}

///|
test "Address::parse secure WebSocket" {
  let addr = Address::parse("wss://example.com:443")
  inspect(addr.protocol, content="Wss")
  inspect(addr.host, content="example.com")
  inspect(addr.port, content="443")
}

///|
test "Address::parse QUIC" {
  let addr = Address::parse("quic://10.0.0.1:1234")
  inspect(addr.protocol, content="Quic")
  inspect(addr.host, content="10.0.0.1")
  inspect(addr.port, content="1234")
}

///|
test "Address::parse IPv6 with brackets" {
  let addr = Address::parse("tcp://[::1]:8000")
  inspect(addr.protocol, content="Tcp")
  inspect(addr.host, content="::1")
  inspect(addr.port, content="8000")
}

///|
test "Address::parse IPv6 full address" {
  let addr = Address::parse("udp://[2001:db8::1]:5000")
  inspect(addr.protocol, content="Udp")
  inspect(addr.host, content="2001:db8::1")
  inspect(addr.port, content="5000")
}

///|
test "Address::to_socket_string IPv4" {
  let addr = Address::new(Tcp, "127.0.0.1", 9000)
  inspect(addr.to_socket_string(), content="127.0.0.1:9000")
}

///|
test "Address::to_socket_string IPv6" {
  let addr = Address::new(Udp, "::1", 8080)
  inspect(addr.to_socket_string(), content="[::1]:8080")
}

///|
test "Address::to_url_string" {
  let addr = Address::new(Ws, "localhost", 3000)
  inspect(addr.to_url_string(), content="ws://localhost:3000")
}

///|
test "Address::parse roundtrip" {
  let original = "tcp://192.168.0.100:6666"
  let addr = Address::parse(original)
  inspect(addr.to_url_string(), content="tcp://192.168.0.100:6666")
}

///|
test "Address::parse missing protocol" {
  let result : Result[Address, _] = Ok(Address::parse("127.0.0.1:9000")) catch {
    e => Err(e)
  }
  inspect(result is Err(_), content="true")
}

///|
test "Address::parse invalid protocol" {
  let result : Result[Address, _] = Ok(Address::parse("http://127.0.0.1:9000")) catch {
    e => Err(e)
  }
  inspect(result is Err(_), content="true")
}

///|
test "Address::parse missing port" {
  let result : Result[Address, _] = Ok(Address::parse("tcp://127.0.0.1")) catch {
    e => Err(e)
  }
  inspect(result is Err(_), content="true")
}

///|
test "Address::parse invalid port" {
  let result : Result[Address, _] = Ok(Address::parse("tcp://127.0.0.1:abc")) catch {
    e => Err(e)
  }
  inspect(result is Err(_), content="true")
}

///|
test "Address ToJson/FromJson roundtrip" {
  let addr = Address::new(Tcp, "10.0.0.1", 8888)
  let json = addr.to_json()
  inspect(json, content="String(\"tcp://10.0.0.1:8888\")")
  let parsed : Address = @json.from_json(json)
  inspect(parsed == addr, content="true")
}

///|
test "Protocol::parse" {
  inspect(Protocol::parse("tcp"), content="Some(Tcp)")
  inspect(Protocol::parse("udp"), content="Some(Udp)")
  inspect(Protocol::parse("ws"), content="Some(Ws)")
  inspect(Protocol::parse("wss"), content="Some(Wss)")
  inspect(Protocol::parse("quic"), content="Some(Quic)")
  inspect(Protocol::parse("http"), content="None")
}
