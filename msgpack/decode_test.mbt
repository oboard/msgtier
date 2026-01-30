// Ported from Deno std msgpack module decoding tests
// Original source: https://github.com/denoland/std/tree/42fd485b615d7cc647c7d2f12610c42d68a597e6/msgpack

// Test decoding positive fixint

///|
test "decode positive fixint" {
  for i = 0; i <= 127; i = i + 1 {
    let data = bytes([i])
    let result = decode(data)
    debug_inspect(result)
  }
}

// Test decoding basic values

///|
test "decode basic values" {
  // Test nil
  let nil_data = bytes([0xc0])
  let nil_result = decode(nil_data)
  debug_inspect(nil_result, content="true")

  // Test false
  let false_data = bytes([0xc2])
  let false_result = decode(false_data)
  debug_inspect(false_result, content="true")

  // Test true
  let true_data = bytes([0xc3])
  let true_result = decode(true_data)
  debug_inspect(true_result, content="true")
}

// Test error cases

///|
test "error cases" {
  // Test empty data
  let empty_data = Bytes::from_array([])
  let result = decode(empty_data)
  debug_inspect(result, content="true")
}
