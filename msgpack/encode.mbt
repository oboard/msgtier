// MessagePack encoder

// Buffer for building MessagePack data

///|
/// Convert string to UTF-8 bytes
fn string_to_utf8_bytes(s : String) -> Bytes {
  let bytes : Array[Byte] = []
  for i = 0; i < s.length(); i = i + 1 {
    let code = s[i].to_int()
    if code < 0x80 {
      // 1-byte sequence (ASCII)
      bytes.push(code.to_byte())
    } else if code < 0x800 {
      // 2-byte sequence
      bytes.push((0xC0 | (code >> 6)).to_byte())
      bytes.push((0x80 | (code & 0x3F)).to_byte())
    } else if code >= 0xD800 && code <= 0xDBFF && i + 1 < s.length() {
      // Surrogate pair (4-byte UTF-8)
      let low = s[i + 1].to_int()
      if low >= 0xDC00 && low <= 0xDFFF {
        let codepoint = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
        bytes.push((0xF0 | (codepoint >> 18)).to_byte())
        bytes.push((0x80 | ((codepoint >> 12) & 0x3F)).to_byte())
        bytes.push((0x80 | ((codepoint >> 6) & 0x3F)).to_byte())
        bytes.push((0x80 | (codepoint & 0x3F)).to_byte())
        continue i + 2
      } else {
        // Invalid surrogate, encode as 3-byte
        bytes.push((0xE0 | (code >> 12)).to_byte())
        bytes.push((0x80 | ((code >> 6) & 0x3F)).to_byte())
        bytes.push((0x80 | (code & 0x3F)).to_byte())
      }
    } else {
      // 3-byte sequence
      bytes.push((0xE0 | (code >> 12)).to_byte())
      bytes.push((0x80 | ((code >> 6) & 0x3F)).to_byte())
      bytes.push((0x80 | (code & 0x3F)).to_byte())
    }
  }
  Bytes::from_array(bytes)
}

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
    Int64(_i64) => {
      // For now, just encode as int32 - this is a simplification
      // In a full implementation, we'd need proper Int64 handling
      buffer.write_byte(INT32_CODE)
      buffer.write_u32(0) // placeholder
    }
    UInt64(_u64) => {
      // For now, just encode as uint32 - this is a simplification
      buffer.write_byte(UINT32_CODE)
      buffer.write_u32(0) // placeholder
    }
    Float(_f) => {
      // For now, just write the float64 code with zero bytes
      // In a full implementation, we'd need proper IEEE 754 encoding
      buffer.write_byte(FLOAT64_CODE)
      buffer.write_u32(0) // high 32 bits
      buffer.write_u32(0) // low 32 bits
    }
    String(s) => {
      // Encode string as UTF-8 and get byte length
      let utf8_bytes = string_to_utf8_bytes(s)
      let len = utf8_bytes.length()
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
      // Write UTF-8 encoded bytes
      for i = 0; i < len; i = i + 1 {
        buffer.write_byte(utf8_bytes[i].to_int())
      }
    }
    Binary(_b) => {
      // For now, just write empty binary
      buffer.write_byte(BIN8_CODE)
      buffer.write_byte(0)
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
