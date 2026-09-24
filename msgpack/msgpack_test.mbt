// Ported from Deno std msgpack module integration tests
// Original source: https://github.com/denoland/std/tree/42fd485b615d7cc647c7d2f12610c42d68a597e6/msgpack

// Test complex data structures

///|
test "complex data structures" {
  // Test nested array
  let inner_array = @msgpack.array([@msgpack.int(1), @msgpack.int(2)])
  let outer_array = @msgpack.array([inner_array, @msgpack.int(3)])
  let encoded = @msgpack.encode(outer_array)
  let decoded = @msgpack.decode(encoded)
  debug_inspect(
    decoded,
    content=(
      #|Array([Array([Int(1), Int(2)]), Int(3)])
    ),
  )

  // Test mixed array
  let mixed_array = @msgpack.array([
    @msgpack.int(42),
    @msgpack.string("hello"),
    @msgpack.bool(true),
    @msgpack.nil(),
  ])
  let encoded_mixed = @msgpack.encode(mixed_array)
  let decoded_mixed = @msgpack.decode(encoded_mixed)
  debug_inspect(
    decoded_mixed,
    content=(
      #|Array([Int(42), String("hello"), Bool(true), Nil])
    ),
  )
}

// Test edge cases

///|
test "edge cases" {
  // Test empty string
  let empty_str = @msgpack.string("")
  let encoded_empty = @msgpack.encode(empty_str)
  let decoded_empty = @msgpack.decode(encoded_empty)
  debug_inspect(
    decoded_empty,
    content=(
      #|String("")
    ),
  )

  // Test zero
  let zero_int = @msgpack.int(0)
  let encoded_zero = @msgpack.encode(zero_int)
  let decoded_zero = @msgpack.decode(encoded_zero)
  debug_inspect(decoded_zero, content="Int(0)")

  // Test maximum positive fixint
  let max_fixint = @msgpack.int(127)
  let encoded_max = @msgpack.encode(max_fixint)
  let decoded_max = @msgpack.decode(encoded_max)
  debug_inspect(decoded_max, content="Int(127)")

  // Test minimum negative fixint
  let min_fixint = @msgpack.int(-32)
  let encoded_min = @msgpack.encode(min_fixint)
  let decoded_min = @msgpack.decode(encoded_min)
  debug_inspect(decoded_min, content="Int(-32)")
}

// Test large data structures

///|
test "large data structures" {
  // Test large array - create smaller for performance
  let values : Array[@msgpack.Value] = []
  for i = 0; i < 20; i = i + 1 {
    values.push(@msgpack.int(i))
  }
  let large_array = @msgpack.array(values)
  let encoded_large = @msgpack.encode(large_array)
  let decoded_large = @msgpack.decode(encoded_large)
  debug_inspect(
    decoded_large,
    content=(
      #|Array(
      #|  [
      #|    Int(0),
      #|    Int(1),
      #|    Int(2),
      #|    Int(3),
      #|    Int(4),
      #|    Int(5),
      #|    Int(6),
      #|    Int(7),
      #|    Int(8),
      #|    Int(9),
      #|    Int(10),
      #|    Int(11),
      #|    Int(12),
      #|    Int(13),
      #|    Int(14),
      #|    Int(15),
      #|    Int(16),
      #|    Int(17),
      #|    Int(18),
      #|    Int(19),
      #|  ],
      #|)
    ),
  )
}

// Test data type validation

///|
test "data type validation" {
  // Test consistent encoding/decoding for all basic types
  let test_data = [
    @msgpack.nil(),
    @msgpack.bool(true),
    @msgpack.bool(false),
    @msgpack.int(0),
    @msgpack.int(42),
    @msgpack.int(-1),
    @msgpack.string("test"),
    @msgpack.array([@msgpack.int(1), @msgpack.int(2)]),
  ]
  debug_inspect(
    test_data.map(x => @msgpack.decode(@msgpack.encode(x))),
    content=(
      #|[
      #|  Nil,
      #|  Bool(true),
      #|  Bool(false),
      #|  Int(0),
      #|  Int(42),
      #|  Int(-1),
      #|  String("test"),
      #|  Array([Int(1), Int(2)]),
      #|]
    ),
  )
}

// Compatibility tests - test Deno sample data

///|
test "deno compatibility tests" {
  // Test data structure from testdata/1.json
  let test_map : Map[String, @msgpack.Value] = Map([], capacity=0)
  test_map["int0"] = @msgpack.int(0)
  test_map["int1"] = @msgpack.int(1)
  test_map["int1-"] = @msgpack.int(-1)
  test_map["nil"] = @msgpack.nil()
  test_map["true"] = @msgpack.bool(true)
  test_map["false"] = @msgpack.bool(false)
  test_map["string0"] = @msgpack.string("")
  test_map["string1"] = @msgpack.string("A")
  let encoded_complex = @msgpack.encode(@msgpack.map(test_map))
  let decoded_complex = @msgpack.decode(encoded_complex)
  debug_inspect(
    decoded_complex,
    content=(
      #|Map(
      #|  {
      #|    "int0": Int(0),
      #|    "int1": Int(1),
      #|    "int1-": Int(-1),
      #|    "nil": Nil,
      #|    "true": Bool(true),
      #|    "false": Bool(false),
      #|    "string0": String(""),
      #|    "string1": String("A"),
      #|  },
      #|)
    ),
  )

  // Test array with different types
  let mixed_types_array = @msgpack.array([
    @msgpack.int(1),
    @msgpack.string("foo"),
    @msgpack.bool(false),
    @msgpack.nil(),
    @msgpack.array([@msgpack.int(1), @msgpack.int(2)]),
  ])
  let encoded_mixed_types = @msgpack.encode(mixed_types_array)
  let decoded_mixed_types = @msgpack.decode(encoded_mixed_types)
  debug_inspect(
    decoded_mixed_types,
    content=(
      #|Array([Int(1), String("foo"), Bool(false), Nil, Array([Int(1), Int(2)])])
    ),
  )
}

// Performance test (simplified version)

///|
test "basic performance test" {
  // Create a reasonably sized data structure
  let perf_map : Map[String, @msgpack.Value] = Map([], capacity=0)
  for i = 0; i < 10; i = i + 1 {
    perf_map["key\{i}"] = @msgpack.int(i)
  }
  let perf_data = @msgpack.map(perf_map)

  // Test multiple encode/decode cycles
  for i = 0; i < 5; i = i + 1 {
    let encoded = @msgpack.encode(perf_data)
    let decoded = @msgpack.decode(encoded)
    debug_inspect(
      decoded,
      content=(
        #|Map(
        #|  {
        #|    "key0": Int(0),
        #|    "key1": Int(1),
        #|    "key2": Int(2),
        #|    "key3": Int(3),
        #|    "key4": Int(4),
        #|    "key5": Int(5),
        #|    "key6": Int(6),
        #|    "key7": Int(7),
        #|    "key8": Int(8),
        #|    "key9": Int(9),
        #|  },
        #|)
      ),
    )
  }
}
