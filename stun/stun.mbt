///|
pub suberror StunError {
  InvalidMessage(String)
  EncodeError(String)
} derive(Show)

///|
pub enum MessageClass {
  Request
  Indication
  SuccessResponse
  ErrorResponse
} derive(Show, Eq)

///|
pub enum MappingBehavior {
  EndpointIndependentMapping
  AddressDependentMapping
  AddressAndPortDependentMapping
  Unsupported
  Unknown
} derive(Show, Eq)

///|
pub enum FilteringBehavior {
  EndpointIndependentFiltering
  AddressDependentFiltering
  AddressAndPortDependentFiltering
  Unsupported
  Unknown
} derive(Show, Eq)

///|
pub enum Attribute {
  XorMappedAddress(String)
  MappedAddress(String)
  OtherAddress(String)
  ChangeRequest(Bool, Bool)
  Software(String)
  ErrorCode(Int, String)
  Fingerprint(UInt)
  Unknown(Int, Bytes)
} derive(Show, Eq)

///|
pub struct Message {
  class_ : MessageClass
  msg_method : Int
  transaction_id : Bytes
  attributes : Array[Attribute]
} derive(Show, Eq)

///|
pub struct BindingProbeResult {
  server_address : String
  mapped_address : String
  other_address : String?
  rtt_ms : Int
  supports_rfc5780 : Bool
} derive(Show, Eq)

///|
pub struct NatProbeResult {
  binding : BindingProbeResult
  mapping_behavior : MappingBehavior
  filtering_behavior : FilteringBehavior
} derive(Show, Eq)

///|
let stun_magic_cookie : Int = 0x2112A442

///|
let stun_header_len : Int = 20

///|
let stun_transaction_id_len : Int = 12

///|
let stun_method_binding : Int = 0x0001

///|
let attr_mapped_address : Int = 0x0001

///|
let attr_change_request : Int = 0x0003

///|
let attr_error_code : Int = 0x0009

///|
let attr_xor_mapped_address : Int = 0x0020

///|
let attr_software : Int = 0x8022

///|
let attr_other_address : Int = 0x802c

///|
let attr_fingerprint : Int = 0x8028

///|
let address_family_ipv4 : Int = 0x01

///|
let global_rng : @random.Rand = @random.Rand::chacha8(seed=build_seed())

///|
fn mix_seed(state : UInt64) -> UInt64 {
  let mut mixed = state
  mixed = mixed ^ (mixed << 13)
  mixed = mixed ^ (mixed >> 7)
  mixed = mixed ^ (mixed << 17)
  mixed
}

///|
fn build_seed() -> Bytes {
  let seed = FixedArray::make(32, b'\x00')
  let mut state = @env.now()
  for arg in @env.args() {
    for c in arg {
      state = mix_seed(state + c.to_int().to_uint64())
    }
  }
  for i = 0; i < 32; i = i + 1 {
    state = mix_seed(state + (i + 1).to_uint64())
    seed[i] = state.to_byte()
  }
  Bytes::from_array(seed)
}

///|
pub fn random_transaction_id() -> Bytes {
  let data = FixedArray::make(stun_transaction_id_len, b'\x00')
  for i = 0; i < stun_transaction_id_len; i = i + 1 {
    data[i] = global_rng.uint(limit=256U).to_byte()
  }
  Bytes::from_array(data)
}

///|
pub fn is_stun_message(raw : Bytes) -> Bool {
  raw.length() >= stun_header_len &&
  read_u32_be(raw, 4) == stun_magic_cookie &&
  (raw[0].to_int() & 0xc0) == 0
}

///|
pub fn build_binding_request(
  change_ip? : Bool = false,
  change_port? : Bool = false,
  transaction_id? : Bytes,
  software? : String = "msgtier",
) -> Message {
  let attributes : Array[Attribute] = []
  if change_ip || change_port {
    attributes.push(ChangeRequest(change_ip, change_port))
  }
  if software != "" {
    attributes.push(Software(software))
  }
  {
    class_: Request,
    msg_method: stun_method_binding,
    transaction_id: transaction_id.unwrap_or(random_transaction_id()),
    attributes,
  }
}

///|
pub fn encode_message(msg : Message) -> Bytes raise StunError {
  guard msg.transaction_id.length() == stun_transaction_id_len else {
    raise EncodeError("transaction id must be 12 bytes")
  }
  let encoded_attrs : Array[Bytes] = []
  let mut attrs_len = 0
  for attr in msg.attributes {
    let encoded = encode_attribute(attr, msg.transaction_id)
    attrs_len = attrs_len + encoded.length()
    encoded_attrs.push(encoded)
  }
  let buf = FixedArray::make(stun_header_len + attrs_len, b'\x00')
  write_u16_be(buf, 0, encode_message_type(msg.msg_method, msg.class_))
  write_u16_be(buf, 2, attrs_len)
  write_u32_be(buf, 4, stun_magic_cookie)
  for i = 0; i < stun_transaction_id_len; i = i + 1 {
    buf[8 + i] = msg.transaction_id[i]
  }
  let mut offset = stun_header_len
  for attr in encoded_attrs {
    for i = 0; i < attr.length(); i = i + 1 {
      buf[offset + i] = attr[i]
    }
    offset = offset + attr.length()
  }
  Bytes::from_array(buf)
}

///|
pub fn decode_message(raw : Bytes) -> Message raise StunError {
  guard raw.length() >= stun_header_len else {
    raise InvalidMessage("message shorter than STUN header")
  }
  guard is_stun_message(raw) else { raise InvalidMessage("not a STUN packet") }
  let encoded_type = read_u16_be(raw, 0)
  let body_len = read_u16_be(raw, 2)
  guard stun_header_len + body_len <= raw.length() else {
    raise InvalidMessage("declared STUN length exceeds packet size")
  }
  let transaction_id = raw[8:20].to_bytes()
  let attrs : Array[Attribute] = []
  let mut offset = stun_header_len
  let end = stun_header_len + body_len
  while offset < end {
    guard offset + 4 <= end else {
      raise InvalidMessage("truncated STUN attribute header")
    }
    let attr_type = read_u16_be(raw, offset)
    let attr_len = read_u16_be(raw, offset + 2)
    let value_start = offset + 4
    let value_end = value_start + attr_len
    guard value_end <= end else {
      raise InvalidMessage("truncated STUN attribute payload")
    }
    let value = raw[value_start:value_end].to_bytes()
    attrs.push(decode_attribute(attr_type, value, transaction_id))
    offset = value_end
    while offset % 4 != 0 && offset < end {
      offset = offset + 1
    }
  }
  {
    class_: decode_message_class(encoded_type),
    msg_method: decode_message_method(encoded_type),
    transaction_id,
    attributes: attrs,
  }
}

///|
pub fn get_mapped_address(msg : Message) -> String? {
  for attr in msg.attributes {
    match attr {
      XorMappedAddress(addr) => return Some(addr)
      MappedAddress(addr) => return Some(addr)
      _ => ()
    }
  }
  None
}

///|
pub fn get_other_address(msg : Message) -> String? {
  for attr in msg.attributes {
    match attr {
      OtherAddress(addr) => return Some(addr)
      _ => ()
    }
  }
  None
}

///|
pub fn classify_mapping_behavior(
  test1_addr : String,
  test2_addr : String,
  test3_addr : String,
) -> MappingBehavior {
  if test1_addr == test2_addr {
    EndpointIndependentMapping
  } else if test2_addr == test3_addr {
    AddressDependentMapping
  } else {
    AddressAndPortDependentMapping
  }
}

///|
pub fn classify_filtering_behavior(
  test2_received : Bool,
  test3_received : Bool,
) -> FilteringBehavior {
  if test2_received {
    EndpointIndependentFiltering
  } else if test3_received {
    AddressDependentFiltering
  } else {
    AddressAndPortDependentFiltering
  }
}

///|
pub async fn probe_binding(
  server : String,
  timeout_ms? : Int = 1500,
  bind_addr? : String = "0.0.0.0:0",
) -> BindingProbeResult? {
  let socket = @socket.UdpServer::new(parse_bind_addr(bind_addr)) catch {
    _ => return None
  }
  defer socket.close()
  let server_addr = resolve_server(server)
  guard server_addr is Some(server_addr) else { return None }
  let request = build_binding_request()
  let start = @env.now()
  let encoded = encode_message(request) catch { _ => return None }
  match (try? socket.sendto(encoded, server_addr)) {
    Ok(_) => ()
    Err(_) => return None
  }
  let response = read_transaction_response(
    socket,
    request.transaction_id,
    timeout_ms,
  )
  guard response is Some(response) else { return None }
  let rtt_ms = (@env.now() - start).to_int()
  guard response.class_ == SuccessResponse else { return None }
  guard get_mapped_address(response) is Some(mapped) else { return None }
  let other_address = get_other_address(response)
  Some(BindingProbeResult::{
    server_address: server_addr.to_string(),
    mapped_address: mapped,
    other_address,
    rtt_ms,
    supports_rfc5780: other_address is Some(_),
  })
}

///|
pub async fn probe_nat_behavior(
  server : String,
  timeout_ms? : Int = 1500,
  bind_addr? : String = "0.0.0.0:0",
) -> NatProbeResult? {
  let socket = @socket.UdpServer::new(parse_bind_addr(bind_addr)) catch {
    _ => return None
  }
  defer socket.close()
  let server_addr = resolve_server(server)
  guard server_addr is Some(server_addr) else { return None }
  let primary = probe_binding_with_socket(socket, server_addr, timeout_ms)
  guard primary is Some(primary) else { return None }
  let binding = BindingProbeResult::{
    server_address: server_addr.to_string(),
    mapped_address: primary.mapped_address,
    other_address: primary.other_address,
    rtt_ms: primary.rtt_ms,
    supports_rfc5780: primary.supports_rfc5780,
  }
  guard primary.other_address is Some(other_addr) else {
    return Some(NatProbeResult::{
      binding,
      mapping_behavior: Unsupported,
      filtering_behavior: Unsupported,
    })
  }
  let alternate = @socket.Addr::parse(other_addr) catch { _ => return None }
  let test2_server = replace_port(alternate, server_addr.port())
  guard test2_server is Some(test2_server) else { return None }
  let test2 = send_binding(socket, test2_server, false, false, timeout_ms)
  let test3 = send_binding(socket, alternate, false, false, timeout_ms)
  guard test2 is Some(test2) && test3 is Some(test3) else {
    return Some(NatProbeResult::{
      binding,
      mapping_behavior: Unknown,
      filtering_behavior: Unknown,
    })
  }
  let mapping_behavior = classify_mapping_behavior(
    primary.mapped_address,
    test2.mapped_address,
    test3.mapped_address,
  )
  let filter_test2 = send_binding(socket, server_addr, true, true, timeout_ms)
  let filter_test3 = send_binding(socket, server_addr, false, true, timeout_ms)
  let filtering_behavior = classify_filtering_behavior(
    filter_test2 is Some(_),
    filter_test3 is Some(_),
  )
  Some(NatProbeResult::{ binding, mapping_behavior, filtering_behavior })
}

///|
async fn send_binding(
  socket : @socket.UdpServer,
  server : @socket.Addr,
  change_ip : Bool,
  change_port : Bool,
  timeout_ms : Int,
) -> BindingProbeResult? {
  probe_binding_with_socket(
    socket,
    server,
    timeout_ms,
    change_ip~,
    change_port~,
  ) catch {
    _ => None
  }
}

///|
pub async fn probe_binding_with_socket(
  socket : @socket.UdpServer,
  server_addr : @socket.Addr,
  timeout_ms : Int,
  change_ip? : Bool = false,
  change_port? : Bool = false,
) -> BindingProbeResult? {
  let request = build_binding_request(change_ip~, change_port~)
  let start = @env.now()
  let encoded = encode_message(request) catch { _ => return None }
  match (try? socket.sendto(encoded, server_addr)) {
    Ok(_) => ()
    Err(_) => return None
  }
  let response = read_transaction_response(
    socket,
    request.transaction_id,
    timeout_ms,
  )
  guard response is Some(response) else { return None }
  guard response.class_ == SuccessResponse else { return None }
  guard get_mapped_address(response) is Some(mapped) else { return None }
  let other_address = get_other_address(response)
  Some(BindingProbeResult::{
    server_address: server_addr.to_string(),
    mapped_address: mapped,
    other_address,
    rtt_ms: (@env.now() - start).to_int(),
    supports_rfc5780: other_address is Some(_),
  })
}

///|
async fn read_transaction_response(
  socket : @socket.UdpServer,
  transaction_id : Bytes,
  timeout_ms : Int,
) -> Message? {
  let buf = FixedArray::make(2048, b'\x00')
  let result = @async.with_timeout_opt(timeout_ms, async fn() {
    for ;; {
      let (n, _) = socket.recvfrom(buf)
      guard n >= stun_header_len else { continue }
      let raw = buf.unsafe_reinterpret_as_bytes()[0:n].to_bytes()
      if !is_stun_message(raw) {
        continue
      }
      let decoded = decode_message(raw) catch { _ => continue }
      if decoded.transaction_id == transaction_id {
        break decoded
      }
    }
  })
  match result {
    Some(msg) => Some(msg)
    None => None
  }
}

///|
fn encode_attribute(
  attr : Attribute,
  transaction_id : Bytes,
) -> Bytes raise StunError {
  let (attr_type, value) = match attr {
    XorMappedAddress(addr) =>
      (
        attr_xor_mapped_address,
        encode_socket_address(addr, true, transaction_id),
      )
    MappedAddress(addr) =>
      (attr_mapped_address, encode_socket_address(addr, false, transaction_id))
    OtherAddress(addr) =>
      (attr_other_address, encode_socket_address(addr, false, transaction_id))
    ChangeRequest(change_ip, change_port) =>
      (attr_change_request, encode_change_request(change_ip, change_port))
    Software(name) => (attr_software, @utf8.encode(name))
    ErrorCode(code, reason) =>
      (attr_error_code, encode_error_code(code, reason))
    Fingerprint(value) =>
      (attr_fingerprint, encode_u32(value.reinterpret_as_int()))
    Unknown(attr_type, value) => (attr_type, value)
  }
  let padded_len = pad4(value.length())
  let buf = FixedArray::make(4 + padded_len, b'\x00')
  write_u16_be(buf, 0, attr_type)
  write_u16_be(buf, 2, value.length())
  for i = 0; i < value.length(); i = i + 1 {
    buf[4 + i] = value[i]
  }
  Bytes::from_array(buf)
}

///|
fn decode_attribute(
  attr_type : Int,
  value : Bytes,
  transaction_id : Bytes,
) -> Attribute raise StunError {
  if attr_type == attr_xor_mapped_address {
    XorMappedAddress(decode_socket_address(value, true, transaction_id))
  } else if attr_type == attr_mapped_address {
    MappedAddress(decode_socket_address(value, false, transaction_id))
  } else if attr_type == attr_other_address {
    OtherAddress(decode_socket_address(value, false, transaction_id))
  } else if attr_type == attr_change_request {
    decode_change_request(value)
  } else if attr_type == attr_software {
    Software(value.to_string())
  } else if attr_type == attr_error_code {
    decode_error_code(value)
  } else if attr_type == attr_fingerprint {
    Fingerprint(read_u32_be_padded(value).reinterpret_as_uint())
  } else {
    Unknown(attr_type, value)
  }
}

///|
fn encode_change_request(change_ip : Bool, change_port : Bool) -> Bytes {
  let buf = FixedArray::make(4, b'\x00')
  let mut flags = 0
  if change_ip {
    flags = flags | 0x04
  }
  if change_port {
    flags = flags | 0x02
  }
  buf[3] = flags.to_byte()
  Bytes::from_array(buf)
}

///|
fn decode_change_request(value : Bytes) -> Attribute raise StunError {
  guard value.length() >= 4 else {
    raise InvalidMessage("CHANGE-REQUEST too short")
  }
  let flags = value[3].to_int()
  ChangeRequest((flags & 0x04) != 0, (flags & 0x02) != 0)
}

///|
fn encode_error_code(code : Int, reason : String) -> Bytes raise StunError {
  guard code >= 300 && code <= 699 else {
    raise EncodeError("invalid STUN error code")
  }
  let reason_bytes = @utf8.encode(reason)
  let buf = FixedArray::make(4 + reason_bytes.length(), b'\x00')
  buf[2] = (code / 100).to_byte()
  buf[3] = (code % 100).to_byte()
  for i = 0; i < reason_bytes.length(); i = i + 1 {
    buf[4 + i] = reason_bytes[i]
  }
  Bytes::from_array(buf)
}

///|
fn decode_error_code(value : Bytes) -> Attribute raise StunError {
  guard value.length() >= 4 else {
    raise InvalidMessage("ERROR-CODE too short")
  }
  let code = value[2].to_int() * 100 + value[3].to_int()
  let reason = if value.length() > 4 {
    value[4:value.length()].to_bytes().to_string()
  } else {
    ""
  }
  ErrorCode(code, reason)
}

///|
fn encode_socket_address(
  socket_addr : String,
  xor_addr : Bool,
  _transaction_id : Bytes,
) -> Bytes raise StunError {
  let addr = @socket.Addr::parse(socket_addr) catch {
    _ => raise EncodeError("invalid socket address " + socket_addr)
  }
  let buf = FixedArray::make(8, b'\x00')
  buf[1] = address_family_ipv4.to_byte()
  let port = addr.port()
  let encoded_port = if xor_addr {
    port ^ ((stun_magic_cookie >> 16) & 0xffff)
  } else {
    port
  }
  write_u16_be(buf, 2, encoded_port)
  let ip = addr.ip().reinterpret_as_int()
  let cookie = cookie_bytes()
  let ip_bytes = [
    ((ip >> 24) & 0xff).to_byte(),
    ((ip >> 16) & 0xff).to_byte(),
    ((ip >> 8) & 0xff).to_byte(),
    (ip & 0xff).to_byte(),
  ]
  for i = 0; i < 4; i = i + 1 {
    buf[4 + i] = if xor_addr { ip_bytes[i] ^ cookie[i] } else { ip_bytes[i] }
  }
  Bytes::from_array(buf)
}

///|
fn decode_socket_address(
  value : Bytes,
  xor_addr : Bool,
  _transaction_id : Bytes,
) -> String raise StunError {
  guard value.length() >= 8 else {
    raise InvalidMessage("address attribute too short")
  }
  let family = value[1].to_int()
  let raw_port = read_u16_be(value, 2)
  let port = if xor_addr {
    raw_port ^ ((stun_magic_cookie >> 16) & 0xffff)
  } else {
    raw_port
  }
  if family == address_family_ipv4 {
    guard value.length() >= 8 else {
      raise InvalidMessage("IPv4 address attribute too short")
    }
    let cookie = cookie_bytes()
    let a = if xor_addr { value[4] ^ cookie[0] } else { value[4] }
    let b = if xor_addr { value[5] ^ cookie[1] } else { value[5] }
    let c = if xor_addr { value[6] ^ cookie[2] } else { value[6] }
    let d = if xor_addr { value[7] ^ cookie[3] } else { value[7] }
    let ip = (a.to_int() << 24) |
      (b.to_int() << 16) |
      (c.to_int() << 8) |
      d.to_int()
    @socket.Addr::new(ip.reinterpret_as_uint(), port).to_string()
  } else {
    raise InvalidMessage("unsupported STUN address family")
  }
}

///|
fn cookie_bytes() -> FixedArray[Byte] {
  let bytes = FixedArray::make(4, b'\x00')
  write_u32_be(bytes, 0, stun_magic_cookie)
  bytes
}

///|
fn encode_message_type(msg_method : Int, class_ : MessageClass) -> Int {
  let class_bits = match class_ {
    Request => 0
    Indication => 1
    SuccessResponse => 2
    ErrorResponse => 3
  }
  (msg_method & 0x000f) |
  ((msg_method & 0x0070) << 1) |
  ((msg_method & 0x0f80) << 2) |
  ((class_bits & 0x1) << 4) |
  ((class_bits & 0x2) << 7)
}

///|
fn decode_message_method(encoded_type : Int) -> Int {
  (encoded_type & 0x000f) |
  ((encoded_type >> 1) & 0x0070) |
  ((encoded_type >> 2) & 0x0f80)
}

///|
fn decode_message_class(encoded_type : Int) -> MessageClass {
  let class_bits = ((encoded_type >> 4) & 0x1) | ((encoded_type >> 7) & 0x2)
  match class_bits {
    0 => Request
    1 => Indication
    2 => SuccessResponse
    _ => ErrorResponse
  }
}

///|
fn read_u16_be(data : Bytes, offset : Int) -> Int {
  (data[offset].to_int() << 8) | data[offset + 1].to_int()
}

///|
fn read_u32_be(data : Bytes, offset : Int) -> Int {
  (data[offset].to_int() << 24) |
  (data[offset + 1].to_int() << 16) |
  (data[offset + 2].to_int() << 8) |
  data[offset + 3].to_int()
}

///|
fn read_u32_be_padded(data : Bytes) -> Int raise StunError {
  guard data.length() >= 4 else {
    raise InvalidMessage("attribute too short for u32 value")
  }
  read_u32_be(data, 0)
}

///|
fn write_u16_be(buf : FixedArray[Byte], offset : Int, value : Int) -> Unit {
  buf[offset] = ((value >> 8) & 0xff).to_byte()
  buf[offset + 1] = (value & 0xff).to_byte()
}

///|
fn write_u32_be(buf : FixedArray[Byte], offset : Int, value : Int) -> Unit {
  buf[offset] = ((value >> 24) & 0xff).to_byte()
  buf[offset + 1] = ((value >> 16) & 0xff).to_byte()
  buf[offset + 2] = ((value >> 8) & 0xff).to_byte()
  buf[offset + 3] = (value & 0xff).to_byte()
}

///|
fn encode_u32(value : Int) -> Bytes {
  let buf = FixedArray::make(4, b'\x00')
  write_u32_be(buf, 0, value)
  Bytes::from_array(buf)
}

///|
fn pad4(value : Int) -> Int {
  if value % 4 == 0 {
    value
  } else {
    value + (4 - value % 4)
  }
}

///|
fn parse_bind_addr(bind_addr : String) -> @socket.Addr {
  @socket.Addr::parse(bind_addr) catch {
    _ => abort("invalid bind address " + bind_addr)
  }
}

///|
pub async fn resolve_server(server : String) -> @socket.Addr? {
  let normalized : String = if server.has_prefix("udp://") {
    server[6:server.length()].to_string()
  } else if server.has_prefix("stun://") {
    server[7:server.length()].to_string()
  } else if server.has_prefix("stun:") {
    server[5:server.length()].to_string()
  } else {
    server
  }
  let direct = match (try? @socket.Addr::parse(normalized)) {
    Ok(addr) => Some(addr)
    Err(_) => None
  }
  match direct {
    Some(addr) => Some(addr)
    None => {
      let parts = if normalized.has_prefix("[") {
        split_ipv6_host_port(normalized)
      } else {
        split_ipv4_host_port(normalized)
      }
      guard parts is Some((host, port)) else { return None }
      match (try? @socket.Addr::resolve(host, port~)) {
        Ok(addr) => Some(addr)
        Err(_) => None
      }
    }
  }
}

///|
fn split_ipv4_host_port(value : String) -> (String, Int)? {
  match value[:].split_once(":") {
    Some((host, port)) =>
      if host.contains(":") || port == "" {
        None
      } else {
        match (try? @strconv.parse_int(port)) {
          Ok(parsed) => Some((host.to_string(), parsed))
          Err(_) => None
        }
      }
    None => None
  }
}

///|
fn split_ipv6_host_port(value : String) -> (String, Int)? {
  match value[:].split_once("]:") {
    Some((host, port)) =>
      if !host.has_prefix("[") || port == "" {
        None
      } else {
        match (try? @strconv.parse_int(port)) {
          Ok(parsed) => Some((host[1:host.length()].to_string(), parsed))
          Err(_) => None
        }
      }
    None => None
  }
}

///|
fn replace_port(addr : @socket.Addr, port : Int) -> @socket.Addr? {
  match
    (try? @socket.Addr::parse(rewrite_socket_port(addr.to_string(), port))) {
    Ok(parsed) => Some(parsed)
    Err(_) => None
  }
}

///|
pub fn rewrite_socket_port(socket_addr : String, port : Int) -> String {
  if socket_addr.has_prefix("[") {
    match socket_addr[:].split_once("]:") {
      Some((host, _)) => host.to_string() + "]:" + port.to_string()
      None => socket_addr
    }
  } else {
    match socket_addr[:].split_once(":") {
      Some((host, _)) => host.to_string() + ":" + port.to_string()
      None => socket_addr
    }
  }
}
