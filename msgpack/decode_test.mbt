// Ported from Deno std msgpack module decoding tests
// Original source: https://github.com/denoland/std/tree/42fd485b615d7cc647c7d2f12610c42d68a597e6/msgpack

// Test decoding positive fixint

///|
test "decode positive fixint" {
  for i = 0; i <= 127; i = i + 1 {
    let data = bytes([i])
    let result = decode(data)
    match result {
      Int(v) => assert_eq(v, i)
      _ => fail("Expected int")
    }
  }
}

// Test decoding basic values

///|
test "decode basic values" {
  // Test nil
  let nil_data = bytes([0xc0])
  let nil_result = decode(nil_data)
  match nil_result {
    Nil => ()
    _ => fail("Expected nil")
  }

  // Test false
  let false_data = bytes([0xc2])
  let false_result = decode(false_data)
  match false_result {
    Bool(false) => ()
    _ => fail("Expected bool false")
  }

  // Test true
  let true_data = bytes([0xc3])
  let true_result = decode(true_data)
  match true_result {
    Bool(true) => ()
    _ => fail("Expected bool true")
  }
}

// Test error cases

///|
test "error cases" {
  // Test empty data
  let empty_data = Bytes::from_array([])
  let result : Result[Value, MsgPackError] = try? decode(empty_data)
  match result {
    Err(InvalidData(_)) => ()
    _ => fail("Expected InvalidData error")
  }
}
