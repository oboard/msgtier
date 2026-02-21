// MessagePack encoder

///|
pub fn encode(value : Value) -> Bytes {
  let buffer = @buffer.new()
  encode_to_buffer(buffer, value)
  buffer.to_bytes()
}

///|
fn encode_to_buffer(buffer : @buffer.Buffer, value : Value) -> Unit {
  match value {
    Nil => buffer.write_byte(NIL_CODE)
    Bool(true) => buffer.write_byte(TRUE_CODE)
    Bool(false) => buffer.write_byte(FALSE_CODE)
    Int(i) =>
      if i >= 0 && i <= 127 {
        // positive fixint: 0x00 - 0x7f
        buffer.write_byte(i.to_byte())
      } else if i >= -32 && i < 0 {
        // negative fixint: 0xe0 - 0xff
        buffer.write_byte(NEGATIVE_FIXINT_CODE | (i & 0x1f).to_byte())
      } else if i >= 128 && i <= 255 {
        // uint8
        buffer.write_byte(0xcc)
        buffer.write_byte(i.to_byte())
      } else if i >= 256 && i <= 65535 {
        // uint16
        buffer.write_byte(0xcd)
        buffer.write_uint16_be(i.to_uint16())
      } else if i >= 65536 {
        // uint32
        buffer.write_byte(0xce)
        buffer.write_uint_be(i.reinterpret_as_uint())
      } else if i >= -128 && i < -32 {
        // int8
        buffer.write_byte(INT8_CODE)
        buffer.write_byte(i.to_byte() & 0xFF)
      } else if i >= -32768 && i < -128 {
        // int16
        buffer.write_byte(INT16_CODE)
        buffer.write_uint16_be(i.to_uint16())
      } else {
        // int32
        buffer.write_byte(INT32_CODE)
        buffer.write_uint_be(i.reinterpret_as_uint())
      }
    Int64(i64) => {
      // Encode Int64 as int64 format
      buffer.write_byte(INT64_CODE)
      buffer.write_int64_be(i64)
    }
    UInt32(u32) => {
      // Encode UInt32 as uint32 format
      buffer.write_byte(UINT32_CODE)
      buffer.write_uint_be(u32)
    }
    UInt64(u64) => {
      // Encode UInt64 as uint64 format
      buffer.write_byte(UINT64_CODE)
      buffer.write_uint64_be(u64)
    }
    Float32(f) => {
      // Encode as Float32 (32-bit IEEE 754)
      buffer.write_byte(FLOAT32_CODE)
      let u32 = f.reinterpret_as_uint()
      buffer.write_uint_be(u32)
    }
    Float64(f) => {
      // Encode as Float64 (64-bit IEEE 754)
      buffer.write_byte(FLOAT64_CODE)
      let u64 = f.reinterpret_as_uint64()
      buffer.write_uint64_be(u64)
    }
    String(s) => {
      let bytes = @utf8.encode(s)
      let len = bytes.length()
      if len <= 31 {
        // fixstr
        buffer.write_byte(FIXSTR_CODE | len.to_byte())
      } else if len <= 255 {
        // str8
        buffer.write_byte(STR8_CODE)
        buffer.write_byte(len.to_byte())
      } else if len <= 65535 {
        // str16
        buffer.write_byte(STR16_CODE)
        buffer.write_uint16_be(len.to_uint16())
      } else {
        // str32
        buffer.write_byte(STR32_CODE)
        buffer.write_uint_be(len.reinterpret_as_uint())
      }
      // Write string bytes
      buffer.write_bytes(bytes)
    }
    Binary(b) => {
      // Encode binary data with length prefix
      let len = b.length()
      if len <= 255 {
        // bin8
        buffer.write_byte(BIN8_CODE)
        buffer.write_byte(len.to_byte())
      } else if len <= 65535 {
        // bin16
        buffer.write_byte(BIN16_CODE)
        buffer.write_uint16_be(len.to_uint16())
      } else {
        // bin32
        buffer.write_byte(BIN32_CODE)
        buffer.write_uint_be(len.reinterpret_as_uint())
      }
      // Write binary bytes
      for i = 0; i < len; i = i + 1 {
        buffer.write_byte(b[i])
      }
    }
    Array(arr) => {
      let len = arr.length()
      if len <= 15 {
        // fixarray
        buffer.write_byte(FIXARRAY_CODE | len.to_byte())
      } else if len <= 65535 {
        // array16
        buffer.write_byte(ARRAY16_CODE)
        buffer.write_uint16_be(len.to_uint16())
      } else {
        // array32
        buffer.write_byte(ARRAY32_CODE)
        buffer.write_uint_be(len.reinterpret_as_uint())
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
        buffer.write_byte(FIXMAP_CODE | len.to_byte())
      } else if len <= 65535 {
        // map16
        buffer.write_byte(MAP16_CODE)
        buffer.write_uint16_be(len.to_uint16())
      } else {
        // map32
        buffer.write_byte(MAP32_CODE)
        buffer.write_uint_be(len.reinterpret_as_uint())
      }
      // Encode each key-value pair
      map.each(fn(key, value) {
        encode_to_buffer(buffer, String(key))
        encode_to_buffer(buffer, value)
      })
    }
  }
}
