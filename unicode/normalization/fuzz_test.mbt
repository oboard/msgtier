///|
/// Property-based fuzz tests for Unicode normalization
/// Tests invariants that should hold for any Unicode string

///|
/// Number of iterations for fuzz tests
let fuzz_iterations : Int = 1000

///|
/// Seed for reproducibility (must be exactly 32 bytes for chacha8)
let fuzz_seed : Bytes = b"unicode-fuzz-seed-for-testing!32"

// =============================================================================
// Property 1: Idempotence - applying normalization twice yields same result
// =============================================================================

///|
test "fuzz: nfc idempotence" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    let s = @fuzz.random_unicode_string(rng, max_len=50)
    let once = @normalization.nfc(s)
    let twice = @normalization.nfc(once)
    assert_eq(once, twice)
  }
}

///|
test "fuzz: nfd idempotence" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    let s = @fuzz.random_unicode_string(rng, max_len=50)
    let once = @normalization.nfd(s)
    let twice = @normalization.nfd(once)
    assert_eq(once, twice)
  }
}

///|
test "fuzz: nfkc idempotence" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    let s = @fuzz.random_unicode_string(rng, max_len=50)
    let once = @normalization.nfkc(s)
    let twice = @normalization.nfkc(once)
    assert_eq(once, twice)
  }
}

///|
test "fuzz: nfkd idempotence" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    let s = @fuzz.random_unicode_string(rng, max_len=50)
    let once = @normalization.nfkd(s)
    let twice = @normalization.nfkd(once)
    assert_eq(once, twice)
  }
}

// =============================================================================
// Property 2: Canonical equivalence - nfc(nfd(s)) == nfc(s)
// =============================================================================

///|
test "fuzz: canonical equivalence via nfd" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    let s = @fuzz.random_unicode_string(rng, max_len=50)
    let via_nfd = @normalization.nfc(@normalization.nfd(s))
    let direct = @normalization.nfc(s)
    assert_eq(via_nfd, direct)
  }
}

///|
test "fuzz: nfd then nfc equals nfc" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    let s = @fuzz.random_unicode_string(rng, max_len=50)
    let nfd_then_nfc = @normalization.nfc(@normalization.nfd(s))
    let just_nfc = @normalization.nfc(s)
    assert_eq(nfd_then_nfc, just_nfc)
  }
}

///|
test "fuzz: nfc then nfd equals nfd" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    let s = @fuzz.random_unicode_string(rng, max_len=50)
    let nfc_then_nfd = @normalization.nfd(@normalization.nfc(s))
    let just_nfd = @normalization.nfd(s)
    assert_eq(nfc_then_nfd, just_nfd)
  }
}

// =============================================================================
// Property 3: Compatibility implies canonical
// =============================================================================

///|
test "fuzz: nfkc of nfc equals nfkc" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    let s = @fuzz.random_unicode_string(rng, max_len=50)
    let nfkc_of_nfc = @normalization.nfkc(@normalization.nfc(s))
    let just_nfkc = @normalization.nfkc(s)
    assert_eq(nfkc_of_nfc, just_nfkc)
  }
}

///|
test "fuzz: nfkd of nfd equals nfkd" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    let s = @fuzz.random_unicode_string(rng, max_len=50)
    let nfkd_of_nfd = @normalization.nfkd(@normalization.nfd(s))
    let just_nfkd = @normalization.nfkd(s)
    assert_eq(nfkd_of_nfd, just_nfkd)
  }
}

// =============================================================================
// Property 4: is_normalized consistency
// =============================================================================

///|
test "fuzz: is_normalized NFC after nfc" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    let s = @fuzz.random_unicode_string(rng, max_len=50)
    let normalized = @normalization.nfc(s)
    assert_true(@normalization.is_normalized(normalized, NFC))
  }
}

///|
test "fuzz: is_normalized NFD after nfd" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    let s = @fuzz.random_unicode_string(rng, max_len=50)
    let normalized = @normalization.nfd(s)
    assert_true(@normalization.is_normalized(normalized, NFD))
  }
}

///|
test "fuzz: is_normalized NFKC after nfkc" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    let s = @fuzz.random_unicode_string(rng, max_len=50)
    let normalized = @normalization.nfkc(s)
    assert_true(@normalization.is_normalized(normalized, NFKC))
  }
}

///|
test "fuzz: is_normalized NFKD after nfkd" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    let s = @fuzz.random_unicode_string(rng, max_len=50)
    let normalized = @normalization.nfkd(s)
    assert_true(@normalization.is_normalized(normalized, NFKD))
  }
}

// =============================================================================
// Property 5: CCC ordering after decomposition
// =============================================================================

///|
test "fuzz: combining marks sorted by CCC after nfd" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<500 {
    let s = @fuzz.random_combining_sequence(rng, base_count=3, mark_count=5)
    let nfd_result = @normalization.nfd(s)
    assert_true(@normalization_fuzz.ccc_is_sorted(nfd_result))
  }
}

///|
test "fuzz: combining marks sorted by CCC after nfkd" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<500 {
    let s = @fuzz.random_combining_sequence(rng, base_count=3, mark_count=5)
    let nfkd_result = @normalization.nfkd(s)
    assert_true(@normalization_fuzz.ccc_is_sorted(nfkd_result))
  }
}

// =============================================================================
// Targeted stress tests
// =============================================================================

///|
test "fuzz: hangul roundtrip" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<500 {
    let s = @fuzz.random_hangul_string(rng, max_len=20)
    // NFD decomposes Hangul, NFC recomposes it
    let roundtrip = @normalization.nfc(@normalization.nfd(s))
    // The roundtrip should be equivalent (but may differ in jamo representation)
    let nfc_original = @normalization.nfc(s)
    assert_eq(roundtrip, nfc_original)
  }
}

///|
test "fuzz: deep decomposition idempotence" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<500 {
    let s = @fuzz.random_deep_decomposition_string(rng, max_len=20)
    let once = @normalization.nfd(s)
    let twice = @normalization.nfd(once)
    assert_eq(once, twice)
  }
}

///|
test "fuzz: mixed content stability" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    let s = @fuzz.random_unicode_string(rng, max_len=100)
    // All four forms should be stable
    let nfc = @normalization.nfc(s)
    let nfd = @normalization.nfd(s)
    let nfkc = @normalization.nfkc(s)
    let nfkd = @normalization.nfkd(s)
    // Each should be idempotent
    assert_eq(@normalization.nfc(nfc), nfc)
    assert_eq(@normalization.nfd(nfd), nfd)
    assert_eq(@normalization.nfkc(nfkc), nfkc)
    assert_eq(@normalization.nfkd(nfkd), nfkd)
  }
}

// =============================================================================
// Empty and boundary cases
// =============================================================================

///|
test "fuzz: empty string" {
  let empty = ""
  assert_eq(@normalization.nfc(empty), "")
  assert_eq(@normalization.nfd(empty), "")
  assert_eq(@normalization.nfkc(empty), "")
  assert_eq(@normalization.nfkd(empty), "")
}

///|
test "fuzz: single combining mark" {
  // A combining mark without a base should still work
  let combining_acute = "\u{0301}" // Combining acute accent
  let nfc = @normalization.nfc(combining_acute)
  let nfd = @normalization.nfd(combining_acute)
  // Should be stable
  assert_eq(@normalization.nfc(nfc), nfc)
  assert_eq(@normalization.nfd(nfd), nfd)
}
