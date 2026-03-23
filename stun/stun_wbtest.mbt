///|
fn expect_message_class(actual : MessageClass, expected : MessageClass) -> Unit {
  if actual != expected {
    abort("unexpected message class")
  }
}

///|
fn has_change_request(
  attrs : Array[Attribute],
  change_ip : Bool,
  change_port : Bool,
) -> Bool {
  for attr in attrs {
    match attr {
      ChangeRequest(ip, port) =>
        if ip == change_ip && port == change_port {
          return true
        }
      _ => ()
    }
  }
  false
}

///|
fn expect_mapping_behavior(
  actual : MappingBehavior,
  expected : MappingBehavior,
) -> Unit {
  if actual != expected {
    abort("unexpected mapping behavior")
  }
}

///|
fn expect_filtering_behavior(
  actual : FilteringBehavior,
  expected : FilteringBehavior,
) -> Unit {
  if actual != expected {
    abort("unexpected filtering behavior")
  }
}

///|
test "binding request encodes and decodes" {
  let transaction_id = Bytes::from_array([
    b'\x00', b'\x01', b'\x02', b'\x03', b'\x04', b'\x05', b'\x06', b'\x07', b'\x08',
    b'\x09', b'\x0a', b'\x0b',
  ])
  let request = build_binding_request(
    change_ip=true,
    change_port=true,
    transaction_id~,
    software="msgtier",
  )
  let encoded = encode_message(request)
  let decoded = decode_message(encoded)
  expect_message_class(decoded.class_, Request)
  if decoded.msg_method != 0x0001 {
    abort("unexpected message method")
  }
  if decoded.transaction_id != transaction_id {
    abort("unexpected transaction id")
  }
  if !has_change_request(decoded.attributes, true, true) {
    abort("missing change request")
  }
}

///|
test "xor mapped address decodes ipv4 correctly" {
  let transaction_id = Bytes::from_array([
    b'\x63', b'\xc7', b'\x11', b'\x7e', b'\x07', b'\x14', b'\x27', b'\x8f', b'\x5d',
    b'\xed', b'\x32', b'\x21',
  ])
  let raw = Bytes::from_array([
    b'\x01', b'\x01', b'\x00', b'\x0c', b'\x21', b'\x12', b'\xa4', b'\x42', b'\x63',
    b'\xc7', b'\x11', b'\x7e', b'\x07', b'\x14', b'\x27', b'\x8f', b'\x5d', b'\xed',
    b'\x32', b'\x21', b'\x00', b'\x20', b'\x00', b'\x08', b'\x00', b'\x01', b'\xa1',
    b'\x47', b'\xe1', b'\x12', b'\xa6', b'\x43',
  ])
  let decoded = decode_message(raw)
  expect_message_class(decoded.class_, SuccessResponse)
  if decoded.transaction_id != transaction_id {
    abort("unexpected transaction id")
  }
  match get_mapped_address(decoded) {
    Some(addr) =>
      if addr != "192.0.2.1:32853" {
        abort("unexpected mapped address")
      }
    None => abort("missing mapped address")
  }
}

///|
test "mapping and filtering classification" {
  expect_mapping_behavior(
    classify_mapping_behavior("1.1.1.1:1000", "1.1.1.1:1000", "1.1.1.1:1001"),
    EndpointIndependentMapping,
  )
  expect_mapping_behavior(
    classify_mapping_behavior("1.1.1.1:1000", "1.1.1.1:1001", "1.1.1.1:1001"),
    AddressDependentMapping,
  )
  expect_mapping_behavior(
    classify_mapping_behavior("1.1.1.1:1000", "1.1.1.1:1001", "1.1.1.1:1002"),
    AddressAndPortDependentMapping,
  )
  expect_filtering_behavior(
    classify_filtering_behavior(true, false),
    EndpointIndependentFiltering,
  )
  expect_filtering_behavior(
    classify_filtering_behavior(false, true),
    AddressDependentFiltering,
  )
  expect_filtering_behavior(
    classify_filtering_behavior(false, false),
    AddressAndPortDependentFiltering,
  )
}
