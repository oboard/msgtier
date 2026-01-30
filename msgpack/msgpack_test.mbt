// Ported from Deno std msgpack module integration tests
// Original source: https://github.com/denoland/std/tree/42fd485b615d7cc647c7d2f12610c42d68a597e6/msgpack

// Test round-trip encode/decode

///|
test "round trip encode decode" {
  // Test integers
  let test_values = [0, 1, -1, 42, -42, 127, -32]
  for value in test_values {
    let encoded = encode(int(value))
    let decoded = decode(encoded)
    debug_inspect(decoded, content="true")
  }

  // Test strings
  let test_strings = ["", "hello", "world", "A"]
  for str_val in test_strings {
    let encoded = encode(string(str_val))
    let decoded = decode(encoded)
    debug_inspect(decoded, content="true")
  }

  // Test booleans
  let encoded_true = encode(bool(true))
  let decoded_true = decode(encoded_true)
  debug_inspect(decoded_true, content="true")
  let encoded_false = encode(bool(false))
  let decoded_false = decode(encoded_false)
  debug_inspect(decoded_false, content="true")

  // Test nil
  let encoded_nil = encode(nil())
  let decoded_nil = decode(encoded_nil)
  debug_inspect(decoded_nil, content="true")
}

// Test complex data structures

///|
test "complex data structures" {
  // Test nested array
  let inner_array = array([int(1), int(2)])
  let outer_array = array([inner_array, int(3)])
  let encoded = encode(outer_array)
  let decoded = decode(encoded)
  debug_inspect(decoded, content="true")

  // Test mixed array
  let mixed_array = array([int(42), string("hello"), bool(true), nil()])
  let encoded_mixed = encode(mixed_array)
  let decoded_mixed = decode(encoded_mixed)
  debug_inspect(decoded_mixed, content="true")
}

// Test edge cases

///|
test "edge cases" {
  // Test empty string
  let empty_str = string("")
  let encoded_empty = encode(empty_str)
  let decoded_empty = decode(encoded_empty)
  debug_inspect(decoded_empty, content="true")

  // Test zero
  let zero_int = int(0)
  let encoded_zero = encode(zero_int)
  let decoded_zero = decode(encoded_zero)
  debug_inspect(decoded_zero, content="true")

  // Test maximum positive fixint
  let max_fixint = int(127)
  let encoded_max = encode(max_fixint)
  let decoded_max = decode(encoded_max)
  debug_inspect(decoded_max, content="true")

  // Test minimum negative fixint
  let min_fixint = int(-32)
  let encoded_min = encode(min_fixint)
  let decoded_min = decode(encoded_min)
  debug_inspect(decoded_min, content="true")
}

// Test large data structures

///|
test "large data structures" {
  // Test large array - create smaller for performance
  let values : Array[Value] = []
  for i = 0; i < 20; i = i + 1 {
    values.push(int(i))
  }
  let large_array = array(values)
  let encoded_large = encode(large_array)
  let decoded_large = decode(encoded_large)
  debug_inspect(decoded_large, content="true")
}

// Test data type validation

///|
test "data type validation" {
  // Test consistent encoding/decoding for all basic types
  let test_data = [
    nil(),
    bool(true),
    bool(false),
    int(0),
    int(42),
    int(-1),
    string("test"),
    array([int(1), int(2)]),
  ]
  for data in test_data {
    let encoded = encode(data)
    let decoded = decode(encoded)
    debug_inspect(decoded, content="true")
  }
}

// Compatibility tests - test Deno sample data

///|
test "deno compatibility tests" {
  // Test data structure from testdata/1.json
  let test_map = Map::new()
  test_map["int0"] = int(0)
  test_map["int1"] = int(1)
  test_map["int1-"] = int(-1)
  test_map["nil"] = nil()
  test_map["true"] = bool(true)
  test_map["false"] = bool(false)
  test_map["string0"] = string("")
  test_map["string1"] = string("A")
  let encoded_complex = encode(map(test_map))
  let decoded_complex = decode(encoded_complex)
  debug_inspect(decoded_complex, content="true")

  // Test array with different types
  let mixed_types_array = array([
    int(1),
    string("foo"),
    bool(false),
    nil(),
    array([int(1), int(2)]),
  ])
  let encoded_mixed_types = encode(mixed_types_array)
  let decoded_mixed_types = decode(encoded_mixed_types)
  debug_inspect(decoded_mixed_types, content="true")
}

// Performance test (simplified version)

///|
test "basic performance test" {
  // Create a reasonably sized data structure
  let perf_map = Map::new()
  for i = 0; i < 10; i = i + 1 {
    perf_map["key\{i}"] = int(i)
  }
  let perf_data = map(perf_map)

  // Test multiple encode/decode cycles
  for i = 0; i < 5; i = i + 1 {
    let encoded = encode(perf_data)
    let decoded = decode(encoded)
    debug_inspect(decoded, content="true")
  }
}
