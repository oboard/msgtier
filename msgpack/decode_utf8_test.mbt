///|
test "decode utf8 string" {
  // "Hello!你好👋"
  // "Hello!" = 6 bytes
  // "你好" = 6 bytes
  // "👋" = 4 bytes
  // Total 16 bytes.
  // fixstr: 0xa0 | 16 = 0xb0
  let utf8_data = @msgpack.encode(@msgpack.string("Hello!你好👋"))
  let result = @msgpack.decode(utf8_data)
  match result {
    String(s) => assert_eq(s, "Hello!你好👋")
    _ => fail("Expected string")
  }
}

///|
test "decode utf8 string in array" {
  let encoded = @msgpack.encode(@msgpack.array([@msgpack.string("喜欢你")]))
  let decoded = @msgpack.decode(encoded)
  match decoded {
    Array(arr) =>
      match arr[0] {
        String(s) => assert_eq(s, "喜欢你")
        _ => fail("Expected string")
      }
    _ => fail("Expected array")
  }
}

///|
test "encode and decode float" {
  let f : Double = 3.14159
  let eps : Double = 0.00001
  let encoded = @msgpack.encode(@msgpack.float64(f))
  let decoded = @msgpack.decode(encoded)
  match decoded {
    @msgpack.Value::Float64(v) => {
      let diff = if v > f { v - f } else { f - v }
      if diff > eps {
        fail("Expected float close to \{f}, got \{v}")
      }
    }
    _ => fail("Expected float")
  }
}
