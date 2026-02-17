// MessagePack decoder

// Simple decoder - returns Result type for error handling

///|
pub fn decode(data : Bytes) -> Value raise MsgPackError {
  if data.length() == 0 {
    raise InvalidData("Empty data")
  }
  let first_byte = data[0]
  match first_byte {
    0xc0 => Nil
    0xc2 => Bool(false)
    0xc3 => Bool(true)
    0xcc => {
      // uint8
      if data.length() < 2 {
        raise InvalidData("Incomplete uint8")
      }
      Int(data[1].to_int())
    }
    0xcd => {
      // uint16
      if data.length() < 3 {
        raise InvalidData("Incomplete uint16")
      }
      let value = (data[1].to_int() << 8) | data[2].to_int()
      Int(value)
    }
    0xce => {
      // uint32
      if data.length() < 5 {
        raise InvalidData("Incomplete uint32")
      }
      let value = (data[1].to_int() << 24) |
        (data[2].to_int() << 16) |
        (data[3].to_int() << 8) |
        data[4].to_int()
      Int(value)
    }
    0xd0 => {
      // int8
      if data.length() < 2 {
        raise InvalidData("Incomplete int8")
      }
      let value = data[1].to_int()
      let signed_value = if value > 127 { value - 256 } else { value }
      Int(signed_value)
    }
    0xd1 => {
      // int16
      if data.length() < 3 {
        raise InvalidData("Incomplete int16")
      }
      let value = (data[1].to_int() << 8) | data[2].to_int()
      let signed_value = if value > 32767 { value - 65536 } else { value }
      Int(signed_value)
    }
    0xd2 => {
      // int32
      if data.length() < 5 {
        raise InvalidData("Incomplete int32")
      }
      let value = (data[1].to_int() << 24) |
        (data[2].to_int() << 16) |
        (data[3].to_int() << 8) |
        data[4].to_int()
      let signed_value = value
      Int(signed_value)
    }
    0xd3 => {
      // int64
      if data.length() < 9 {
        raise InvalidData("Incomplete int64")
      }
      let high = (data[1].to_int() << 24) |
        (data[2].to_int() << 16) |
        (data[3].to_int() << 8) |
        data[4].to_int()
      let low = (data[5].to_int() << 24) |
        (data[6].to_int() << 16) |
        (data[7].to_int() << 8) |
        data[8].to_int()
      // Combine high and low into Int64
      let i64_value = high.to_int64() * 0x100000000L + low.to_int64()
      Int64(i64_value)
    }
    0xcf => {
      // uint64
      if data.length() < 9 {
        raise InvalidData("Incomplete uint64")
      }
      let high = (data[1].to_int() << 24) |
        (data[2].to_int() << 16) |
        (data[3].to_int() << 8) |
        data[4].to_int()
      let low = (data[5].to_int() << 24) |
        (data[6].to_int() << 16) |
        (data[7].to_int() << 8) |
        data[8].to_int()
      // Combine high and low into UInt64
      let u64_value = high.reinterpret_as_uint().to_uint64() * 0x100000000UL +
        low.reinterpret_as_uint().to_uint64()
      UInt64(u64_value)
    }
    0xca => {
      // float32
      if data.length() < 5 {
        raise InvalidData("Incomplete float32")
      }
      let val_bits = (data[1].to_int() << 24) |
        (data[2].to_int() << 16) |
        (data[3].to_int() << 8) |
        data[4].to_int()
      Float32(Float::reinterpret_from_int(val_bits))
    }
    0xcb => {
      // float64
      if data.length() < 9 {
        raise InvalidData("Incomplete float64")
      }
      let high = (data[1].to_int() << 24) |
        (data[2].to_int() << 16) |
        (data[3].to_int() << 8) |
        data[4].to_int()
      let low = (data[5].to_int() << 24) |
        (data[6].to_int() << 16) |
        (data[7].to_int() << 8) |
        data[8].to_int()
      let u64_bits = high.to_int64() * 0x100000000L + low.to_int64()
      Float64(u64_bits.reinterpret_as_double())
    }
    0xc4 => {
      // bin8
      if data.length() < 2 {
        raise InvalidData("Incomplete bin8 length")
      }
      let bin_length = data[1].to_int()
      if data.length() < 2 + bin_length {
        raise InvalidData("Incomplete bin8 data")
      }
      let bin_bytes : Array[Byte] = []
      for i = 0; i < bin_length; i = i + 1 {
        bin_bytes.push(data[2 + i])
      }
      Binary(Bytes::from_array(bin_bytes))
    }
    0xc5 => {
      // bin16
      if data.length() < 3 {
        raise InvalidData("Incomplete bin16 length")
      }
      let bin_length = (data[1].to_int() << 8) | data[2].to_int()
      if data.length() < 3 + bin_length {
        raise InvalidData("Incomplete bin16 data")
      }
      let bin_bytes : Array[Byte] = []
      for i = 0; i < bin_length; i = i + 1 {
        bin_bytes.push(data[3 + i])
      }
      Binary(Bytes::from_array(bin_bytes))
    }
    0xc6 => {
      // bin32
      if data.length() < 5 {
        raise InvalidData("Incomplete bin32 length")
      }
      let bin_length = (data[1].to_int() << 24) |
        (data[2].to_int() << 16) |
        (data[3].to_int() << 8) |
        data[4].to_int()
      if data.length() < 5 + bin_length {
        raise InvalidData("Incomplete bin32 data")
      }
      let bin_bytes : Array[Byte] = []
      for i = 0; i < bin_length; i = i + 1 {
        bin_bytes.push(data[5 + i])
      }
      Binary(Bytes::from_array(bin_bytes))
    }
    0xd9 => {
      // str8 (1-byte length)
      if data.length() < 2 {
        raise InvalidData("Incomplete str8 length")
      }
      let str_length = data[1].to_int()
      if data.length() < 2 + str_length {
        raise InvalidData("Incomplete str8 data")
      }
      decode_string_bytes(data, 2, str_length)
    }
    0xda => {
      // str16 (2-byte length)
      if data.length() < 3 {
        raise InvalidData("Incomplete str16 length")
      }
      let str_length = (data[1].to_int() << 8) | data[2].to_int()
      if data.length() < 3 + str_length {
        raise InvalidData("Incomplete str16 data")
      }
      decode_string_bytes(data, 3, str_length)
    }
    0xdb => {
      // str32 (4-byte length)
      if data.length() < 5 {
        raise InvalidData("Incomplete str32 length")
      }
      let str_length = (data[1].to_int() << 24) |
        (data[2].to_int() << 16) |
        (data[3].to_int() << 8) |
        data[4].to_int()
      if data.length() < 5 + str_length {
        raise InvalidData("Incomplete str32 data")
      }
      decode_string_bytes(data, 5, str_length)
    }
    0xdc => {
      // array16
      if data.length() < 3 {
        raise InvalidData("Incomplete array16")
      }
      let array_length = (data[1].to_int() << 8) | data[2].to_int()
      match decode_array(data, 3, array_length) {
        (value, _) => value
      }
    }
    0xdd => {
      // array32
      if data.length() < 5 {
        raise InvalidData("Incomplete array32")
      }
      let array_length = (data[1].to_int() << 24) |
        (data[2].to_int() << 16) |
        (data[3].to_int() << 8) |
        data[4].to_int()
      match decode_array(data, 5, array_length) {
        (value, _) => value
      }
    }
    0xde => {
      // map16
      if data.length() < 3 {
        raise InvalidData("Incomplete map16")
      }
      let map_length = (data[1].to_int() << 8) | data[2].to_int()
      match decode_map(data, 3, map_length) {
        (value, _) => value
      }
    }
    0xdf => {
      // map32
      if data.length() < 5 {
        raise InvalidData("Incomplete map32")
      }
      let map_length = (data[1].to_int() << 24) |
        (data[2].to_int() << 16) |
        (data[3].to_int() << 8) |
        data[4].to_int()
      match decode_map(data, 5, map_length) {
        (value, _) => value
      }
    }
    _ =>
      if (first_byte.to_int() & 0x80) == 0 {
        // positive fixint
        Int(first_byte.to_int())
      } else if (first_byte.to_int() & 0xe0) == 0xe0 {
        // negative fixint
        Int(first_byte.to_int() - 256)
      } else if (first_byte.to_int() & 0xe0) == 0xa0 {
        // fixstr
        let str_length = first_byte.to_int() & 0x1f
        if data.length() < str_length + 1 {
          raise InvalidData("Incomplete fixstr")
        }
        decode_string_bytes(data, 1, str_length)
      } else if (first_byte.to_int() & 0xf0) == 0x90 {
        // fixarray
        let array_length = first_byte.to_int() & 0x0f
        match decode_array(data, 1, array_length) {
          (value, _) => value
        }
      } else if (first_byte.to_int() & 0xf0) == 0x80 {
        // fixmap
        let map_length = first_byte.to_int() & 0x0f
        match decode_map(data, 1, map_length) {
          (value, _) => value
        }
      } else {
        raise InvalidData("Unsupported format")
      }
  }
}

// Helper function to decode string bytes

///|
fn decode_string_bytes(
  data : Bytes,
  offset : Int,
  length : Int,
) -> Value raise MsgPackError {
  String(@utf8.decode(data[offset:offset + length])) catch {
    _ => raise InvalidData("Invalid UTF-8 string")
  }
}

// Helper functions for decoding complex types

///|
fn decode_array(
  data : Bytes,
  start_offset : Int,
  length : Int,
) -> (Value, Int) raise MsgPackError {
  let array : Array[Value] = []
  let mut offset = start_offset
  for i = 0; i < length; i = i + 1 {
    if offset >= data.length() {
      raise InvalidData("Incomplete array data")
    }
    match decode_value_at_offset(data, offset) {
      (value, new_offset) => {
        array.push(value)
        offset = new_offset
      }
    }
  }
  (Array(array), offset)
}

///|
fn decode_map(
  data : Bytes,
  start_offset : Int,
  length : Int,
) -> (Value, Int) raise MsgPackError {
  let map = Map::new()
  let mut offset = start_offset
  for i = 0; i < length; i = i + 1 {
    if offset >= data.length() {
      raise InvalidData("Incomplete map data")
    }
    // Decode key
    match decode_value_at_offset(data, offset) {
      (key_value, new_offset1) => {
        offset = new_offset1
        match key_value {
          String(key) =>
            // Decode value
            match decode_value_at_offset(data, offset) {
              (value, new_offset2) => {
                map[key] = value
                offset = new_offset2
              }
            }
          _ => raise InvalidData("Map key must be string")
        }
      }
    }
  }
  (Map(map), offset)
}

///|
fn decode_value_at_offset(
  data : Bytes,
  offset : Int,
) -> (Value, Int) raise MsgPackError {
  if offset >= data.length() {
    raise InvalidData("Offset out of bounds")
  }
  let first_byte = data[offset]
  match first_byte.to_int() {
    0xc0 => (Nil, offset + 1)
    0xc2 => (Bool(false), offset + 1)
    0xc3 => (Bool(true), offset + 1)
    0xcc => {
      // uint8
      if offset + 1 >= data.length() {
        raise InvalidData("Incomplete uint8")
      }
      (Int(data[offset + 1].to_int()), offset + 2)
    }
    0xcd => {
      // uint16
      if offset + 2 >= data.length() {
        raise InvalidData("Incomplete uint16")
      }
      let value = (data[offset + 1].to_int() << 8) | data[offset + 2].to_int()
      (Int(value), offset + 3)
    }
    0xce => {
      // uint32
      if offset + 4 >= data.length() {
        raise InvalidData("Incomplete uint32")
      }
      let value = (data[offset + 1].to_int() << 24) |
        (data[offset + 2].to_int() << 16) |
        (data[offset + 3].to_int() << 8) |
        data[offset + 4].to_int()
      (Int(value), offset + 5)
    }
    0xdc => {
      // array16
      if offset + 2 >= data.length() {
        raise InvalidData("Incomplete array16")
      }
      let array_length = (data[offset + 1].to_int() << 8) |
        data[offset + 2].to_int()
      decode_array(data, offset + 3, array_length)
    }
    0xde => {
      // map16
      if offset + 2 >= data.length() {
        raise InvalidData("Incomplete map16")
      }
      let map_length = (data[offset + 1].to_int() << 8) |
        data[offset + 2].to_int()
      decode_map(data, offset + 3, map_length)
    }
    0xd0 => {
      // int8
      if offset + 1 >= data.length() {
        raise InvalidData("Incomplete int8")
      }
      let value = data[offset + 1].to_int()
      let signed_value = if value > 127 { value - 256 } else { value }
      (Int(signed_value), offset + 2)
    }
    0xd1 => {
      // int16
      if offset + 2 >= data.length() {
        raise InvalidData("Incomplete int16")
      }
      let value = (data[offset + 1].to_int() << 8) | data[offset + 2].to_int()
      let signed_value = if value > 32767 { value - 65536 } else { value }
      (Int(signed_value), offset + 3)
    }
    0xd2 => {
      // int32
      if offset + 4 >= data.length() {
        raise InvalidData("Incomplete int32")
      }
      let value = (data[offset + 1].to_int() << 24) |
        (data[offset + 2].to_int() << 16) |
        (data[offset + 3].to_int() << 8) |
        data[offset + 4].to_int()
      (Int(value), offset + 5)
    }
    0xd3 => {
      // int64
      if offset + 8 >= data.length() {
        raise InvalidData("Incomplete int64")
      }
      let high = (data[offset + 1].to_int() << 24) |
        (data[offset + 2].to_int() << 16) |
        (data[offset + 3].to_int() << 8) |
        data[offset + 4].to_int()
      let low = (data[offset + 5].to_int() << 24) |
        (data[offset + 6].to_int() << 16) |
        (data[offset + 7].to_int() << 8) |
        data[offset + 8].to_int()
      let i64_value = high.to_int64() * 0x100000000L + low.to_int64()
      (Int64(i64_value), offset + 9)
    }
    0xcf => {
      // uint64
      if offset + 8 >= data.length() {
        raise InvalidData("Incomplete uint64")
      }
      let high = (data[offset + 1].to_int() << 24) |
        (data[offset + 2].to_int() << 16) |
        (data[offset + 3].to_int() << 8) |
        data[offset + 4].to_int()
      let low = (data[offset + 5].to_int() << 24) |
        (data[offset + 6].to_int() << 16) |
        (data[offset + 7].to_int() << 8) |
        data[offset + 8].to_int()
      let u64_value = high.reinterpret_as_uint().to_uint64() * 0x100000000UL +
        low.reinterpret_as_uint().to_uint64()
      (UInt64(u64_value), offset + 9)
    }
    0xca => {
      // float32
      if offset + 4 >= data.length() {
        raise InvalidData("Incomplete float32")
      }
      let val_bits = (data[offset + 1].to_int() << 24) |
        (data[offset + 2].to_int() << 16) |
        (data[offset + 3].to_int() << 8) |
        data[offset + 4].to_int()
      (Float32(Float::reinterpret_from_int(val_bits)), offset + 5)
    }
    0xcb => {
      // float64
      if offset + 8 >= data.length() {
        raise InvalidData("Incomplete float64")
      }
      let high = (data[offset + 1].to_int() << 24) |
        (data[offset + 2].to_int() << 16) |
        (data[offset + 3].to_int() << 8) |
        data[offset + 4].to_int()
      let low = (data[offset + 5].to_int() << 24) |
        (data[offset + 6].to_int() << 16) |
        (data[offset + 7].to_int() << 8) |
        data[offset + 8].to_int()
      let u64_bits = (high.to_int64() << 32) | (low.to_int64() & 0xFFFFFFFFL)
      (Float64(u64_bits.reinterpret_as_double()), offset + 9)
    }
    0xc4 => {
      // bin8
      if offset + 1 >= data.length() {
        raise InvalidData("Incomplete bin8 length")
      }
      let bin_length = data[offset + 1].to_int()
      if offset + 2 + bin_length > data.length() {
        raise InvalidData("Incomplete bin8 data")
      }
      let bin_bytes : Array[Byte] = []
      for i = 0; i < bin_length; i = i + 1 {
        bin_bytes.push(data[offset + 2 + i])
      }
      (Binary(Bytes::from_array(bin_bytes)), offset + 2 + bin_length)
    }
    0xc5 => {
      // bin16
      if offset + 2 >= data.length() {
        raise InvalidData("Incomplete bin16 length")
      }
      let bin_length = (data[offset + 1].to_int() << 8) |
        data[offset + 2].to_int()
      if offset + 3 + bin_length > data.length() {
        raise InvalidData("Incomplete bin16 data")
      }
      let bin_bytes : Array[Byte] = []
      for i = 0; i < bin_length; i = i + 1 {
        bin_bytes.push(data[offset + 3 + i])
      }
      (Binary(Bytes::from_array(bin_bytes)), offset + 3 + bin_length)
    }
    0xc6 => {
      // bin32
      if offset + 4 >= data.length() {
        raise InvalidData("Incomplete bin32 length")
      }
      let bin_length = (data[offset + 1].to_int() << 24) |
        (data[offset + 2].to_int() << 16) |
        (data[offset + 3].to_int() << 8) |
        data[offset + 4].to_int()
      if offset + 5 + bin_length > data.length() {
        raise InvalidData("Incomplete bin32 data")
      }
      let bin_bytes : Array[Byte] = []
      for i = 0; i < bin_length; i = i + 1 {
        bin_bytes.push(data[offset + 5 + i])
      }
      (Binary(Bytes::from_array(bin_bytes)), offset + 5 + bin_length)
    }
    0xdd => {
      // array32
      if offset + 4 >= data.length() {
        raise InvalidData("Incomplete array32")
      }
      let array_length = (data[offset + 1].to_int() << 24) |
        (data[offset + 2].to_int() << 16) |
        (data[offset + 3].to_int() << 8) |
        data[offset + 4].to_int()
      decode_array(data, offset + 5, array_length)
    }
    0xdf => {
      // map32
      if offset + 4 >= data.length() {
        raise InvalidData("Incomplete map32")
      }
      let map_length = (data[offset + 1].to_int() << 24) |
        (data[offset + 2].to_int() << 16) |
        (data[offset + 3].to_int() << 8) |
        data[offset + 4].to_int()
      decode_map(data, offset + 5, map_length)
    }
    0xd9 => {
      // str8 (1-byte length)
      if offset + 1 >= data.length() {
        raise InvalidData("Incomplete str8 length")
      }
      let str_length = data[offset + 1].to_int()
      if offset + 2 + str_length > data.length() {
        raise InvalidData("Incomplete str8 data")
      }
      (
        decode_string_bytes(data, offset + 2, str_length),
        offset + 2 + str_length,
      )
    }
    0xda => {
      // str16 (2-byte length)
      if offset + 2 >= data.length() {
        raise InvalidData("Incomplete str16 length")
      }
      let str_length = (data[offset + 1].to_int() << 8) |
        data[offset + 2].to_int()
      if offset + 3 + str_length > data.length() {
        raise InvalidData("Incomplete str16 data")
      }
      (
        decode_string_bytes(data, offset + 3, str_length),
        offset + 3 + str_length,
      )
    }
    0xdb => {
      // str32 (4-byte length)
      if offset + 4 >= data.length() {
        raise InvalidData("Incomplete str32 length")
      }
      let str_length = (data[offset + 1].to_int() << 24) |
        (data[offset + 2].to_int() << 16) |
        (data[offset + 3].to_int() << 8) |
        data[offset + 4].to_int()
      if offset + 5 + str_length > data.length() {
        raise InvalidData("Incomplete str32 data")
      }
      (
        decode_string_bytes(data, offset + 5, str_length),
        offset + 5 + str_length,
      )
    }
    _ =>
      if (first_byte.to_int() & 0x80) == 0 {
        // positive fixint
        (Int(first_byte.to_int()), offset + 1)
      } else if (first_byte.to_int() & 0xe0) == 0xe0 {
        // negative fixint
        (Int(first_byte.to_int() - 256), offset + 1)
      } else if (first_byte.to_int() & 0xe0) == 0xa0 {
        let str_length = first_byte.to_int() & 0x1f
        if offset + str_length >= data.length() {
          raise InvalidData("Incomplete fixstr")
        }
        (
          decode_string_bytes(data, offset + 1, str_length),
          offset + str_length + 1,
        )
      } else if (first_byte.to_int() & 0xf0) == 0x90 {
        // fixarray
        let array_length = first_byte.to_int() & 0x0f
        decode_array(data, offset + 1, array_length)
      } else if (first_byte.to_int() & 0xf0) == 0x80 {
        // fixmap
        let map_length = first_byte.to_int() & 0x0f
        decode_map(data, offset + 1, map_length)
      } else {
        raise InvalidData("Unsupported format: 0x\{first_byte.to_hex()}")
      }
  }
}
