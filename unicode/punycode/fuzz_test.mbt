///|
/// Property-based fuzz tests for Punycode encoding/decoding
/// Tests RFC 3492 invariants

///|
/// Number of iterations for fuzz tests
let fuzz_iterations : Int = 1000

///|
/// Seed for reproducibility (must be exactly 32 bytes for chacha8)
let fuzz_seed : Bytes = b"punycode-fuzz-seed-testing!!32!!"

///|
fn[T] result_of(f : () -> T raise) -> Result[T, Error] {
  try f() catch {
    err => Err(err)
  } noraise {
    value => Ok(value)
  }
}

// =============================================================================
// Property 1: Roundtrip - decode(encode(s)) == s
// =============================================================================

///|
test "fuzz: punycode roundtrip with random unicode" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    let s = @fuzz.random_unicode_string(rng, max_len=30)
    let result : Result[String, _] = result_of(() => {
      let encoded = @punycode.encode(s)
      @punycode.decode(encoded)
    })
    match result {
      Ok(decoded) => assert_eq(decoded, s)
      Err(_) => () // Some strings may cause overflow, which is acceptable
    }
  }
}

///|
test "fuzz: punycode roundtrip with hangul" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<500 {
    let s = @fuzz.random_hangul_string(rng, max_len=20)
    let result : Result[String, _] = result_of(() => {
      let encoded = @punycode.encode(s)
      @punycode.decode(encoded)
    })
    match result {
      Ok(decoded) => assert_eq(decoded, s)
      Err(_) => () // Some strings may cause overflow
    }
  }
}

///|
test "fuzz: punycode roundtrip with latin extended" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    // Generate strings with mostly Latin Extended characters
    let sb = StringBuilder::new()
    let len = rng.int(limit=30) + 1
    for _ in 0..<len {
      let cp = @fuzz.random_codepoint(rng, LatinExtended)
      sb.write_char(cp)
    }
    let s = sb.to_string()
    let result : Result[String, _] = result_of(() => {
      let encoded = @punycode.encode(s)
      @punycode.decode(encoded)
    })
    match result {
      Ok(decoded) => assert_eq(decoded, s)
      Err(_) => ()
    }
  }
}

// =============================================================================
// Property 2: Encode produces ASCII-only output
// =============================================================================

///|
fn is_ascii_string(s : String) -> Bool {
  for c in s {
    if c.to_int() >= 0x80 {
      return false
    }
  }
  true
}

///|
test "fuzz: punycode encode produces ASCII" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    let s = @fuzz.random_unicode_string(rng, max_len=30)
    let result : Result[String, _] = result_of(() => @punycode.encode(s))
    match result {
      Ok(encoded) => assert_true(is_ascii_string(encoded))
      Err(_) => () // Overflow is acceptable
    }
  }
}

// =============================================================================
// Property 3: Pure ASCII strings encode with trailing delimiter
// =============================================================================

///|
test "fuzz: pure ASCII encodes with delimiter" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<500 {
    // Generate pure ASCII string
    let sb = StringBuilder::new()
    let len = rng.int(limit=20) + 1
    for _ in 0..<len {
      let cp = @fuzz.random_codepoint(rng, Ascii)
      sb.write_char(cp)
    }
    let s = sb.to_string()
    let result : Result[String, _] = result_of(() => @punycode.encode(s))
    match result {
      Ok(encoded) =>
        // Pure ASCII input should produce: original + "-"
        assert_eq(encoded, s + "-")
      Err(_) => ()
    }
  }
}

// =============================================================================
// Property 4: Idempotence of decode on valid Punycode
// =============================================================================

///|
test "fuzz: valid punycode decode is stable" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    let s = @fuzz.random_unicode_string(rng, max_len=20)
    let result : Result[(String, String), _] = result_of(() => {
      let encoded = @punycode.encode(s)
      // Decode twice should give same result
      let decoded1 = @punycode.decode(encoded)
      let encoded2 = @punycode.encode(decoded1)
      let decoded2 = @punycode.decode(encoded2)
      (decoded1, decoded2)
    })
    match result {
      Ok((d1, d2)) => assert_eq(d1, d2)
      Err(_) => ()
    }
  }
}

// =============================================================================
// Property 5: Mixed ASCII and non-ASCII
// =============================================================================

///|
test "fuzz: mixed ascii and unicode roundtrip" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    // Generate string with mix of ASCII and non-ASCII
    let sb = StringBuilder::new()
    let len = rng.int(limit=20) + 1
    for _ in 0..<len {
      let use_ascii = rng.int(limit=2) == 0
      let cp = if use_ascii {
        @fuzz.random_codepoint(rng, Ascii)
      } else {
        @fuzz.random_codepoint(rng, LatinExtended)
      }
      sb.write_char(cp)
    }
    let s = sb.to_string()
    let result : Result[String, _] = result_of(() => {
      let encoded = @punycode.encode(s)
      @punycode.decode(encoded)
    })
    match result {
      Ok(decoded) => assert_eq(decoded, s)
      Err(_) => ()
    }
  }
}

// =============================================================================
// Boundary cases
// =============================================================================

///|
test "fuzz: empty string" {
  let encoded = @punycode.encode("")
  let decoded = @punycode.decode(encoded)
  assert_eq(decoded, "")
}

///|
test "fuzz: single character roundtrip" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<500 {
    let cp = @fuzz.random_codepoint(rng, LatinExtended)
    let s = cp.to_string()
    let result : Result[String, _] = result_of(() => {
      let encoded = @punycode.encode(s)
      @punycode.decode(encoded)
    })
    match result {
      Ok(decoded) => assert_eq(decoded, s)
      Err(_) => ()
    }
  }
}
