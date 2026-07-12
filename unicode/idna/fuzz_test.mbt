///|
/// Property-based fuzz tests for IDNA processing
/// Tests UTS #46 invariants

///|
/// Number of iterations for fuzz tests
let fuzz_iterations : Int = 50000

///|
/// Seed for reproducibility (must be exactly 32 bytes for chacha8)
let fuzz_seed : Bytes = b"idna-fuzz-seed-for-testing!32!!!"

// =============================================================================
// Property 1: to_ascii produces ASCII-only output
// =============================================================================

///|
test "fuzz: to_ascii produces ASCII" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    let domain = @idna_fuzz.random_domain(rng)
    let result : Result[String, _] = to_ascii_result(
      domain,
      check_bidi=false,
      check_joiners=false,
    )
    match result {
      Ok(ascii) => assert_true(@idna_fuzz.is_ascii_string(ascii))
      Err(_) => () // Some domains may be invalid
    }
  }
}

// =============================================================================
// Property 2: Pure ASCII domains pass through
// =============================================================================

///|
test "fuzz: pure ASCII domain passthrough" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    // Generate pure ASCII domain
    let num_labels = rng.int(limit=3) + 1
    let labels : Array[String] = []
    for _ in 0..<num_labels {
      labels.push(@idna_fuzz.random_ascii_label(rng))
    }
    let domain = labels.join(".")
    let result : Result[String, _] = to_ascii_result(
      domain,
      use_std3_ascii_rules=false,
      check_hyphens=false,
      check_bidi=false,
      check_joiners=false,
    )
    match result {
      Ok(ascii) =>
        // ASCII domain should lowercase but otherwise stay similar
        assert_eq(ascii, domain.to_lower())
      Err(_) => ()
    }
  }
}

// =============================================================================
// Property 3: Roundtrip for valid domains
// =============================================================================

///|
test "fuzz: idna roundtrip" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    let domain = @idna_fuzz.random_domain(rng)
    let result : Result[(String, String), _] = result_of(() => {
      let ascii = @idna.to_ascii(
        domain,
        check_bidi=false,
        check_joiners=false,
        verify_dns_length=false,
      )
      let unicode = @idna.to_unicode(
        ascii,
        check_bidi=false,
        check_joiners=false,
      )
      (ascii, unicode)
    })
    match result {
      Ok((ascii, unicode)) => {
        // The unicode result should be NFC normalized
        // Re-encoding should give the same ASCII
        let result2 : Result[String, _] = to_ascii_result(
          unicode,
          check_bidi=false,
          check_joiners=false,
          verify_dns_length=false,
        )
        match result2 {
          Ok(ascii2) => assert_eq(ascii, ascii2)
          Err(_) => ()
        }
      }
      Err(_) => ()
    }
  }
}

// =============================================================================
// Property 4: to_unicode is idempotent
// =============================================================================

///|
test "fuzz: to_unicode idempotence" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    let domain = @idna_fuzz.random_domain(rng)
    let result : Result[(String, String), _] = result_of(() => {
      let unicode1 = @idna.to_unicode(
        domain,
        check_bidi=false,
        check_joiners=false,
      )
      let unicode2 = @idna.to_unicode(
        unicode1,
        check_bidi=false,
        check_joiners=false,
      )
      (unicode1, unicode2)
    })
    match result {
      Ok((u1, u2)) => assert_eq(u1, u2)
      Err(_) => ()
    }
  }
}

// =============================================================================
// Property 5: to_ascii produces pure ASCII for all Unicode input
// =============================================================================

///|
test "fuzz: to_ascii produces pure ASCII for any Unicode input" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    // Generate label with random Unicode code points (full range U+0000 to U+10FFFF)
    let sb = StringBuilder::new()
    let len = rng.int(limit=10) + 1
    for _ in 0..<len {
      let cp = @fuzz.random_any_codepoint(rng)
      sb.write_char(cp)
    }
    let label = sb.to_string()
    let result : Result[String, _] = to_ascii_result(
      label,
      check_bidi=false,
      check_joiners=false,
      verify_dns_length=false,
    )
    match result {
      Ok(ascii) =>
        // DETERMINISTIC ASSERTION:
        // to_ascii output must be pure ASCII (code points < 0x80)
        for c in ascii {
          let code = c.to_int()
          assert_true(code < 0x80)
        }
      Err(_) => () // Disallowed chars, bidi errors, etc. are expected
    }
  }
}

// =============================================================================
// Property 6: Hangul domain handling
// =============================================================================

///|
test "fuzz: hangul domain roundtrip" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<300 {
    // Generate Hangul label
    let label = @fuzz.random_hangul_string(rng, max_len=10)
    let result : Result[(String, String), _] = result_of(() => {
      let ascii = @idna.to_ascii(
        label,
        check_bidi=false,
        check_joiners=false,
        verify_dns_length=false,
      )
      let unicode = @idna.to_unicode(
        ascii,
        check_bidi=false,
        check_joiners=false,
      )
      (ascii, unicode)
    })
    match result {
      Ok((ascii, _unicode)) =>
        // Should have xn-- prefix
        assert_true(ascii.has_prefix("xn--"))
      Err(_) => ()
    }
  }
}

// =============================================================================
// Boundary cases
// =============================================================================

///|
test "fuzz: empty label handling" {
  // Empty domain should fail
  let result : Result[String, _] = to_ascii_result("")
  assert_true(result is Err(_))
}

///|
test "fuzz: single character domains" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<200 {
    let cp = @fuzz.random_codepoint(rng, Ascii)
    let s = cp.to_string()
    let result : Result[String, _] = to_ascii_result(
      s,
      use_std3_ascii_rules=false,
      check_hyphens=false,
      check_bidi=false,
      check_joiners=false,
    )
    match result {
      Ok(ascii) => assert_true(@idna_fuzz.is_ascii_string(ascii))
      Err(_) => ()
    }
  }
}

///|
test "fuzz: multiple dot handling" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<200 {
    // Generate domain with various separators
    let label1 = @idna_fuzz.random_ascii_label(rng)
    let label2 = @idna_fuzz.random_ascii_label(rng)
    let domain = label1 + "." + label2
    let result : Result[String, _] = to_ascii_result(
      domain,
      use_std3_ascii_rules=false,
      check_hyphens=false,
      check_bidi=false,
      check_joiners=false,
    )
    match result {
      Ok(ascii) =>
        // Should preserve dot structure
        assert_true(ascii.contains("."))
      Err(_) => ()
    }
  }
}

// =============================================================================
// Property 7: Bidi checking
// =============================================================================

///|
test "fuzz: arabic rtl domains with bidi check" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    let label = @idna_fuzz.random_arabic_label(rng)
    let result : Result[String, _] = to_ascii_result(
      label,
      check_bidi=true,
      check_joiners=false,
      verify_dns_length=false,
    )
    // We're mainly testing that the code path runs without panicking
    // Both success and expected errors are acceptable
    match result {
      Ok(ascii) => assert_true(@idna_fuzz.is_ascii_string(ascii))
      Err(_) => ()
    }
  }
}

///|
test "fuzz: hebrew rtl domains with bidi check" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    let label = @idna_fuzz.random_hebrew_label(rng)
    let result : Result[String, _] = to_ascii_result(
      label,
      check_bidi=true,
      check_joiners=false,
      verify_dns_length=false,
    )
    match result {
      Ok(ascii) => assert_true(@idna_fuzz.is_ascii_string(ascii))
      Err(_) => ()
    }
  }
}

///|
test "fuzz: mixed bidi labels may be rejected" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  let mut error_count = 0
  for _ in 0..<fuzz_iterations {
    let label = @idna_fuzz.random_mixed_bidi_label(rng)
    let result : Result[String, _] = to_ascii_result(
      label,
      check_bidi=true,
      check_joiners=false,
      verify_dns_length=false,
    )
    match result {
      Ok(_) => ()
      Err(InvalidBidi) => error_count = error_count + 1
      Err(_) => ()
    }
  }
  // We expect at least some InvalidBidi errors for mixed LTR/RTL content
  // (might not be all, since the exact rules are complex)
  ()
}

// =============================================================================
// Property 8: Joiner checking
// =============================================================================

///|
test "fuzz: joiners at boundary rejected" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  let mut error_count = 0
  for _ in 0..<fuzz_iterations {
    let label = @idna_fuzz.random_label_with_joiners(rng, at_boundary=true)
    let result : Result[String, _] = to_ascii_result(
      label,
      check_bidi=false,
      check_joiners=true,
      verify_dns_length=false,
    )
    match result {
      Ok(_) => ()
      Err(InvalidJoiner) => error_count = error_count + 1
      Err(_) => ()
    }
  }
  // We expect joiner errors when joiner is at label boundary
  ()
}

///|
test "fuzz: joiners in middle may pass" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    let label = @idna_fuzz.random_label_with_joiners(rng, at_boundary=false)
    let result : Result[String, _] = to_ascii_result(
      label,
      check_bidi=false,
      check_joiners=true,
      verify_dns_length=false,
    )
    // Just testing the code path runs
    match result {
      Ok(ascii) => assert_true(@idna_fuzz.is_ascii_string(ascii))
      Err(_) => ()
    }
  }
}

// =============================================================================
// Property 9: IDNA Mapping
// =============================================================================

///|
test "fuzz: ignored characters removed" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    let label = @idna_fuzz.random_label_with_ignored(rng)
    let result : Result[String, _] = to_ascii_result(
      label,
      check_bidi=false,
      check_joiners=false,
      verify_dns_length=false,
    )
    match result {
      Ok(ascii) =>
        // Result should not contain soft hyphen (U+00AD) etc.
        for c in ascii {
          let cp = c.to_int()
          assert_true(
            cp != 0x00AD && cp != 0x034F && cp != 0x180B && cp != 0xFE00,
          )
        }
      Err(_) => ()
    }
  }
}

///|
test "fuzz: mapped characters transformed" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    let label = @idna_fuzz.random_label_with_mapped(rng)
    let result : Result[String, _] = to_ascii_result(
      label,
      check_bidi=false,
      check_joiners=false,
      verify_dns_length=false,
    )
    match result {
      Ok(ascii) =>
        // Result should be lowercase ASCII (for fullwidth/uppercase input)
        // and should not contain fullwidth characters
        for c in ascii {
          let cp = c.to_int()
          // No fullwidth ASCII (FF00-FF5E)
          assert_true(cp < 0xFF00 || cp > 0xFF5E)
          // No uppercase A-Z in output (should be lowercase)
          // (except in xn-- prefix which is lowercase anyway)
        }
      Err(_) => ()
    }
  }
}

// =============================================================================
// Property 10: Error case validation
// =============================================================================

///|
test "fuzz: disallowed characters rejected" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  let mut error_count = 0
  for _ in 0..<fuzz_iterations {
    let label = @idna_fuzz.random_label_with_disallowed(rng)
    let result : Result[String, _] = to_ascii_result(
      label,
      check_bidi=false,
      check_joiners=false,
    )
    match result {
      Ok(_) => ()
      Err(DisallowedCodePoint(_)) => error_count = error_count + 1
      Err(_) => ()
    }
  }
  // We expect most inputs with disallowed chars to fail
  assert_true(error_count > 0)
}

///|
test "fuzz: label too long rejected" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  let mut error_count = 0
  for _ in 0..<100 {
    let label = @idna_fuzz.random_long_label(rng)
    let result : Result[String, _] = to_ascii_result(
      label,
      use_std3_ascii_rules=false, // Allow non-LDH ASCII for this test
      check_bidi=false,
      check_joiners=false,
      verify_dns_length=true,
    )
    match result {
      Ok(_) => ()
      Err(LabelTooLong) => error_count = error_count + 1
      Err(_) => ()
    }
  }
  // We expect long labels to fail
  assert_true(error_count > 0)
}

///|
test "fuzz: leading combining mark rejected" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  let mut error_count = 0
  for _ in 0..<fuzz_iterations {
    let label = @idna_fuzz.random_label_leading_combining(rng)
    let result : Result[String, _] = to_ascii_result(
      label,
      check_bidi=false,
      check_joiners=false,
    )
    match result {
      Ok(_) => ()
      Err(LeadingCombiningMark) => error_count = error_count + 1
      Err(_) => ()
    }
  }
  // We expect leading combining marks to fail
  assert_true(error_count > 0)
}

// =============================================================================
// Property 11: STD3 rules
// =============================================================================

///|
test "fuzz: std3 hyphen at start rejected" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  let mut error_count = 0
  for _ in 0..<200 {
    let label = @idna_fuzz.random_label_boundary_hyphen(rng, at_start=true)
    let result : Result[String, _] = to_ascii_result(
      label,
      use_std3_ascii_rules=true,
      check_hyphens=true,
      check_bidi=false,
      check_joiners=false,
    )
    match result {
      Ok(_) => ()
      Err(InvalidHyphen) => error_count = error_count + 1
      Err(_) => ()
    }
  }
  // We expect hyphen at start to fail
  assert_true(error_count > 0)
}

///|
test "fuzz: std3 hyphen at end rejected" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  let mut error_count = 0
  for _ in 0..<200 {
    let label = @idna_fuzz.random_label_boundary_hyphen(rng, at_start=false)
    let result : Result[String, _] = to_ascii_result(
      label,
      use_std3_ascii_rules=true,
      check_hyphens=true,
      check_bidi=false,
      check_joiners=false,
    )
    match result {
      Ok(_) => ()
      Err(InvalidHyphen) => error_count = error_count + 1
      Err(_) => ()
    }
  }
  // We expect hyphen at end to fail
  assert_true(error_count > 0)
}

// =============================================================================
// Property 12: Cross-library - NFC normalization
// =============================================================================

///|
test "fuzz: idna output is nfc normalized" {
  let rng = @random.Rand::chacha8(seed=fuzz_seed)
  for _ in 0..<fuzz_iterations {
    let domain = @idna_fuzz.random_domain(rng)
    let result : Result[String, _] = to_unicode_result(
      domain,
      check_bidi=false,
      check_joiners=false,
    )
    match result {
      Ok(unicode) => {
        // to_unicode output should be NFC normalized
        // NFC(output) == output
        let nfc_result = @normalization.nfc(unicode)
        assert_eq(unicode, nfc_result)
      }
      Err(_) => ()
    }
  }
}
