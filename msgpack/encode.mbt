// MessagePack encoder

// Buffer for building MessagePack data

///|
priv struct Buffer {
  bytes : Array[Int]
}

///|
fn Buffer::new() -> Buffer {
  { bytes: [] }
}

///|
fn Buffer::write_byte(self : Buffer, byte : Int) -> Unit {
  self.bytes.push(byte)
}

///|
fn Buffer::write_u16(self : Buffer, value : Int) -> Unit {
  self.write_byte((value >> 8) & 0xFF)
  self.write_byte(value & 0xFF)
}

///|
fn Buffer::write_u32(self : Buffer, value : Int) -> Unit {
  self.write_byte((value >> 24) & 0xFF)
  self.write_byte((value >> 16) & 0xFF)
  self.write_byte((value >> 8) & 0xFF)
  self.write_byte(value & 0xFF)
}

///|
fn Buffer::write_i64(self : Buffer, value : Int64) -> Unit {
  // Write Int64 as 8 bytes in big-endian format
  // Extract high and low 32 bits
  let high = (value >> 32).to_int()
  let low = value.to_int()
  self.write_u32(high)
  self.write_u32(low)
}

///|
fn Buffer::write_u64(self : Buffer, value : UInt64) -> Unit {
  // Write UInt64 as 8 bytes in big-endian format
  // Extract high and low 32 bits
  let high = (value >> 32).to_int()
  let low = value.to_int()
  self.write_u32(high)
  self.write_u32(low)
}

///|
fn Buffer::to_bytes(self : Buffer) -> Bytes {
  let arr : Array[Byte] = []
  for i in self.bytes {
    arr.push(i.to_byte())
  }
  Bytes::from_array(arr)
}

// MessagePack encoder

///|
pub fn encode(value : Value) -> Bytes {
  let buffer = Buffer::new()
  encode_to_buffer(buffer, value)
  buffer.to_bytes()
}

///|
fn encode_to_buffer(buffer : Buffer, value : Value) -> Unit {
  match value {
    Nil => buffer.write_byte(NIL_CODE)
    Bool(true) => buffer.write_byte(TRUE_CODE)
    Bool(false) => buffer.write_byte(FALSE_CODE)
    Int(i) =>
      if i >= 0 && i <= 127 {
        // positive fixint: 0x00 - 0x7f
        buffer.write_byte(i)
      } else if i >= -32 && i < 0 {
        // negative fixint: 0xe0 - 0xff
        buffer.write_byte(NEGATIVE_FIXINT_CODE | (i & 0x1f))
      } else if i >= 128 && i <= 255 {
        // uint8
        buffer.write_byte(0xcc)
        buffer.write_byte(i)
      } else if i >= 256 && i <= 65535 {
        // uint16
        buffer.write_byte(0xcd)
        buffer.write_u16(i)
      } else if i >= 65536 {
        // uint32
        buffer.write_byte(0xce)
        buffer.write_u32(i)
      } else if i >= -128 && i < -32 {
        // int8
        buffer.write_byte(INT8_CODE)
        buffer.write_byte(i & 0xFF)
      } else if i >= -32768 && i < -128 {
        // int16
        buffer.write_byte(INT16_CODE)
        buffer.write_u16(i)
      } else {
        // int32
        buffer.write_byte(INT32_CODE)
        buffer.write_u32(i)
      }
    Int64(i64) => {
      // Encode Int64 as int64 format
      buffer.write_byte(INT64_CODE)
      buffer.write_i64(i64)
    }
    UInt64(u64) => {
      // Encode UInt64 as uint64 format
      buffer.write_byte(UINT64_CODE)
      buffer.write_u64(u64)
    }
    Float(_) => {
      // Encode as Float64 (64-bit IEEE 754)
      // First convert to bits - this is tricky in MoonBit
      // For now use 0xcb format and write 8 zero bytes as placeholder
      // A full implementation would need float-to-bits conversion
      buffer.write_byte(FLOAT64_CODE)
      // Write placeholder 64 bits (0.0)
      buffer.write_u32(0)
      buffer.write_u32(0)
    }
    String(s) => {
      let len = s.length()
      if len <= 31 {
        // fixstr
        buffer.write_byte(FIXSTR_CODE | len)
      } else if len <= 255 {
        // str8
        buffer.write_byte(STR8_CODE)
        buffer.write_byte(len)
      } else if len <= 65535 {
        // str16
        buffer.write_byte(STR16_CODE)
        buffer.write_u16(len)
      } else {
        // str32
        buffer.write_byte(STR32_CODE)
        buffer.write_u32(len)
      }
      // Write string bytes
      for i = 0; i < len; i = i + 1 {
        buffer.write_byte(s[i].to_byte().to_int())
      }
    }
    Binary(b) => {
      // Encode binary data with length prefix
      let len = b.length()
      if len <= 255 {
        // bin8
        buffer.write_byte(BIN8_CODE)
        buffer.write_byte(len)
      } else if len <= 65535 {
        // bin16
        buffer.write_byte(BIN16_CODE)
        buffer.write_u16(len)
      } else {
        // bin32
        buffer.write_byte(BIN32_CODE)
        buffer.write_u32(len)
      }
      // Write binary bytes
      for i = 0; i < len; i = i + 1 {
        buffer.write_byte(b[i].to_int())
      }
    }
    Array(arr) => {
      let len = arr.length()
      if len <= 15 {
        // fixarray
        buffer.write_byte(FIXARRAY_CODE | len)
      } else if len <= 65535 {
        // array16
        buffer.write_byte(ARRAY16_CODE)
        buffer.write_u16(len)
      } else {
        // array32
        buffer.write_byte(ARRAY32_CODE)
        buffer.write_u32(len)
      }
      // Encode each element
      for i = 0; i < len; i = i + 1 {
        encode_to_buffer(buffer, arr[i])
      }
    }
    Map(map) => {
      let len = map.length()
      if len <= 15 {
        // fixmap
        buffer.write_byte(FIXMAP_CODE | len)
      } else if len <= 65535 {
        // map16
        buffer.write_byte(MAP16_CODE)
        buffer.write_u16(len)
      } else {
        // map32
        buffer.write_byte(MAP32_CODE)
        buffer.write_u32(len)
      }
      // Encode each key-value pair
      map.each(fn(key, value) {
        encode_to_buffer(buffer, String(key))
        encode_to_buffer(buffer, value)
      })
    }
  }
}
