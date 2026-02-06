///|
pub fn parse_header(data : BytesView) -> Header? {
  if data.length() < 1 {
    return None
  }
  let first = data[0]
  let is_long = (first.to_int() & 0x80) != 0
  if is_long {
    parse_long_header(data)
  } else {
    parse_short_header(data)
  }
}

///|
fn parse_long_header(data : BytesView) -> Header? {
  // 1-byte Flags, 4-byte Version, 1-byte DCID Len, DCID, 1-byte SCID Len, SCID
  if data.length() < 6 {
    return None
  }
  let version = (data[1].to_uint() << 24) |
    (data[2].to_uint() << 16) |
    (data[3].to_uint() << 8) |
    data[4].to_uint()
  let dcid_len = data[5].to_int()
  if data.length() < 6 + dcid_len + 1 {
    return None
  }
  let dcid = data[6:dcid_len]
  let offset = 6 + dcid_len
  let scid_len = data[offset].to_int()
  if data.length() < offset + 1 + scid_len {
    return None
  }
  let scid = data[offset + 1:scid_len]
  Some({
    first_byte: data[0],
    version: Some(version),
    dest_cid: dcid,
    src_cid: Some(scid),
    packet_number: 0L,
    payload_length: None,
  })
}

///|
fn parse_short_header(data : BytesView) -> Header? {
  Some({
    first_byte: data[0],
    version: None,
    dest_cid: b"",
    src_cid: None,
    packet_number: 0L,
    payload_length: None,
  })
}
