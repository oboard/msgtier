///|
/// Tests for IDNA processing (UTS #46)

///|
test "to_ascii: pure ASCII domain" {
  inspect(to_ascii("example.com"), content="example.com")
}

///|
test "to_ascii: simple IDN" {
  // münchen.de -> xn--mnchen-3ya.de
  inspect(to_ascii("münchen.de"), content="xn--mnchen-3ya.de")
}

///|
test "to_ascii: Chinese domain" {
  // 中文.com
  inspect(to_ascii("中文.com"), content="xn--fiq228c.com")
}

///|
test "to_ascii: Japanese domain" {
  // ドメイン.jp
  inspect(to_ascii("ドメイン.jp"), content="xn--eckwd4c7c.jp")
}

///|
test "to_ascii: mixed ASCII and Unicode" {
  inspect(to_ascii("bücher.example.com"), content="xn--bcher-kva.example.com")
}

///|
test "to_ascii: uppercase conversion" {
  inspect(to_ascii("EXAMPLE.COM"), content="example.com")
}

///|
test "to_ascii: fullwidth separators" {
  // Fullwidth full stop U+FF0E should be treated as separator
  inspect(to_ascii("example\u{FF0E}com"), content="example.com")
}

///|
test "to_unicode: pure ASCII domain" {
  inspect(to_unicode("example.com"), content="example.com")
}

///|
test "to_unicode: Punycode domain" {
  // xn--mnchen-3ya.de -> münchen.de
  inspect(to_unicode("xn--mnchen-3ya.de"), content="münchen.de")
}

///|
test "to_unicode: Chinese Punycode" {
  inspect(to_unicode("xn--fiq228c.com"), content="中文.com")
}

///|
test "roundtrip: German" {
  let original = "münchen.de"
  let ascii = to_ascii(original)
  let back = to_unicode(ascii)
  assert_eq(back, original)
}

///|
test "roundtrip: Chinese" {
  let original = "中文.com"
  let ascii = to_ascii(original)
  let back = to_unicode(ascii)
  assert_eq(back, original)
}

///|
test "roundtrip: Japanese" {
  let original = "ドメイン.jp"
  let ascii = to_ascii(original)
  let back = to_unicode(ascii)
  assert_eq(back, original)
}

///|
test "roundtrip: Korean" {
  let original = "한국어.kr"
  let ascii = to_ascii(original)
  let back = to_unicode(ascii)
  assert_eq(back, original)
}

///|
test "roundtrip: Russian" {
  let original = "пример.ru"
  let ascii = to_ascii(original)
  let back = to_unicode(ascii)
  assert_eq(back, original)
}

///|
test "invalid: disallowed character" {
  // U+0000 is disallowed
  let result = to_ascii_result("example\u{0000}.com")
  guard result is Err(_) else {
    fail("Expected error for disallowed character")
  }
}

///|
test "to_ascii: double dots handled" {
  // Double dots create an empty label which triggers EmptyLabel error
  let result = to_ascii_result("example..com")
  guard result is Err(@idna.EmptyLabel) else { fail("Expected EmptyLabel") }
}

///|
test "to_ascii: label too long" {
  // Create a label that will be > 63 characters after Punycode encoding
  // This is hard to test directly, so we test with already long ASCII
  let long_label = "a".repeat(64)
  let result = to_ascii_result(long_label + ".com")
  guard result is Err(_) else { fail("Expected error for label too long") }
}

///|
test "mapping: ignored characters" {
  // Soft hyphen U+00AD is ignored
  inspect(to_ascii("exam\u{00AD}ple.com"), content="example.com")
}

///|
test "mapping: mapped characters" {
  // U+00DF (ß) maps to "ss"
  inspect(to_ascii("straße.de"), content="xn--strae-oqa.de")
}

///|
test "validation: hyphen at start" {
  let result = to_ascii_result("-example.com")
  guard result is Err(_) else { fail("Expected error for hyphen at start") }
}

///|
test "validation: hyphen at end" {
  let result = to_ascii_result("example-.com")
  guard result is Err(_) else { fail("Expected error for hyphen at end") }
}

///|
test "std3 rules: space character rejected" {
  // Space U+0020 is rejected with STD3 rules (default) - not LDH
  let result = to_ascii_result("exam ple.com")
  guard result is Err(_) else {
    fail("Expected error for space with STD3 rules")
  }
}

///|
test "std3 disabled: space character allowed" {
  // Space U+0020 is allowed without STD3 rules (marked "valid" in IDNA table)
  let result = to_ascii("exam ple.com", use_std3_ascii_rules=false)
  inspect(result, content="exam ple.com")
}

///|
test "std3 disabled: allows some characters" {
  // Without STD3 rules, some characters are allowed
  let result = to_ascii(
    "example.com",
    use_std3_ascii_rules=false,
    check_hyphens=false,
  )
  inspect(result, content="example.com")
}

///|
test "to_ascii: ideographic full stop" {
  // Ideographic full stop U+3002 should be treated as separator
  inspect(to_ascii("中文\u{3002}com"), content="xn--fiq228c.com")
}

///|
test "to_ascii: multiple labels" {
  inspect(
    to_ascii("münchen.example.中文.com"),
    content="xn--mnchen-3ya.example.xn--fiq228c.com",
  )
}

///|
test "to_unicode: mixed Punycode and ASCII" {
  inspect(
    to_unicode("xn--mnchen-3ya.example.com"),
    content="münchen.example.com",
  )
}

///|
test "case folding: uppercase to lowercase" {
  inspect(to_ascii("MÜNCHEN.DE"), content="xn--mnchen-3ya.de")
}

// =============================================================================
// Bidi validation tests (RFC 5893)
// =============================================================================

///|
test "bidi: valid RTL label starting with Arabic letter" {
  // Arabic domain - starts with AL (Arabic Letter)
  // U+0645 (م) is Arabic Letter with bidi class AL
  let result = to_ascii("مثال.com", check_bidi=true)
  assert_true(result.has_prefix("xn--"))
}

///|
test "bidi: valid RTL label with Hebrew" {
  // Hebrew domain - starts with R (Right-to-Left)
  // U+05D0 (א) is Hebrew with bidi class R
  let result = to_ascii("בדיקה.com", check_bidi=true)
  assert_true(result.has_prefix("xn--"))
}

///|
test "bidi: RTL label cannot start with L character" {
  // Mix Hebrew (R) with leading Latin (L) - invalid
  // This label has RTL chars but doesn't start with R/AL
  let result = to_ascii_result("aבדיקה.com", check_bidi=true)
  guard result is Err(@idna.InvalidBidi) else { fail("Expected InvalidBidi") }
}

///|
test "bidi: RTL label cannot contain L character" {
  // Hebrew label with Latin in the middle - L not allowed in RTL
  let result = to_ascii_result("בדaיקה.com", check_bidi=true)
  guard result is Err(@idna.InvalidBidi) else { fail("Expected InvalidBidi") }
}

///|
test "bidi: RTL label cannot have both EN and AN" {
  // Arabic with both European Number and Arabic Number - invalid
  // U+0660-U+0669 are Arabic-Indic digits (AN)
  // 0-9 are European Numbers (EN)
  let result = to_ascii_result("مثال1\u{0660}.com", check_bidi=true)
  guard result is Err(@idna.InvalidBidi) else { fail("Expected InvalidBidi") }
}

///|
test "bidi: LTR label cannot contain RTL characters" {
  // Latin label with Arabic character - invalid for LTR
  let result = to_ascii_result("exampleم.com", check_bidi=true)
  guard result is Err(@idna.InvalidBidi) else { fail("Expected InvalidBidi") }
}

///|
test "bidi: pure ASCII label passes bidi check" {
  // Pure ASCII is LTR and valid
  let result = to_ascii("example.com", check_bidi=true)
  inspect(result, content="example.com")
}

///|
test "bidi: disabled check allows mixed bidi" {
  // With bidi check disabled, mixed content is allowed
  let result = to_ascii("exampleم.com", check_bidi=false)
  assert_true(result.has_prefix("xn--"))
}

// =============================================================================
// ContextJ validation tests (RFC 5892 - ZWNJ and ZWJ)
// =============================================================================

///|
test "contextj: ZWNJ after Virama is valid" {
  // Devanagari Virama (U+094D) followed by ZWNJ (U+200C)
  // क् + ZWNJ - valid context
  let result = to_ascii_result(
    "क\u{094D}\u{200C}ष.com",
    check_joiners=true,
    check_bidi=false,
  )
  assert_true(result is Ok(_))
}

///|
test "contextj: ZWNJ without valid context fails" {
  // ZWNJ at start of label - no valid context
  let result = to_ascii_result("\u{200C}example.com", check_joiners=true)
  guard result is Err(@idna.InvalidJoiner) else {
    fail("Expected InvalidJoiner")
  }
}

///|
test "contextj: ZWNJ between non-joining chars fails" {
  // ZWNJ between Latin characters - invalid
  let result = to_ascii_result("ex\u{200C}ample.com", check_joiners=true)
  guard result is Err(@idna.InvalidJoiner) else {
    fail("Expected InvalidJoiner")
  }
}

///|
test "contextj: ZWJ after Virama is valid" {
  // Devanagari Virama (U+094D) followed by ZWJ (U+200D)
  let result = to_ascii_result(
    "क\u{094D}\u{200D}ष.com",
    check_joiners=true,
    check_bidi=false,
  )
  assert_true(result is Ok(_))
}

///|
test "contextj: ZWJ without Virama fails" {
  // ZWJ without preceding Virama - invalid
  let result = to_ascii_result("ex\u{200D}ample.com", check_joiners=true)
  guard result is Err(@idna.InvalidJoiner) else {
    fail("Expected InvalidJoiner")
  }
}

///|
test "contextj: ZWJ at start of label fails" {
  // ZWJ at start - no preceding character
  let result = to_ascii_result("\u{200D}example.com", check_joiners=true)
  guard result is Err(@idna.InvalidJoiner) else {
    fail("Expected InvalidJoiner")
  }
}

///|
test "contextj: disabled check allows joiners anywhere" {
  // With joiner check disabled, ZWNJ/ZWJ are allowed
  // ZWNJ is a Deviation character (not Ignored), so it stays in the string
  let result = to_ascii("ex\u{200C}ample.com", check_joiners=false)
  inspect(result, content="xn--example-9z6c.com")
}

// =============================================================================
// ACE prefix validation tests
// =============================================================================

///|
test "ace: valid Punycode decodes correctly" {
  // Test that a known Punycode domain decodes correctly
  let result = to_unicode("xn--mnchen-3ya.de")
  inspect(result, content="münchen.de")
}

///|
test "ace: invalid Punycode after xn-- fails" {
  // Invalid Punycode sequence after xn--
  let result = to_unicode_result("xn--###invalid.com")
  assert_true(result is Err(_))
}

///|
test "ace: uppercase XN-- prefix works" {
  // ACE prefix is case-insensitive
  let result = to_unicode("XN--MNCHEN-3YA.de")
  inspect(result, content="münchen.de")
}

///|
test "ace: mixed case xN-- prefix works" {
  let result = to_unicode("xN--mnchen-3ya.de")
  inspect(result, content="münchen.de")
}

// =============================================================================
// Leading combining mark tests
// =============================================================================

///|
test "combining mark: at start of label fails" {
  // U+0301 (Combining Acute Accent) at start - invalid
  let result = to_ascii_result("\u{0301}example.com")
  guard result is Err(@idna.LeadingCombiningMark) else {
    fail("Expected LeadingCombiningMark")
  }
}

///|
test "combining mark: after base character is valid" {
  // e + combining acute = é (valid)
  let result = to_ascii("caf\u{0065}\u{0301}.com")
  // NFC normalizes to café
  assert_true(result.contains("caf"))
}

///|
test "combining mark: multiple marks after base is valid" {
  // Base + multiple combining marks
  let result = to_ascii_result("a\u{0301}\u{0327}.com", check_bidi=false)
  assert_true(result is Ok(_))
}

///|
test "combining mark: U+0300 grave at start fails" {
  // U+0300 (Combining Grave Accent) at start
  let result = to_ascii_result("\u{0300}test.com")
  guard result is Err(@idna.LeadingCombiningMark) else {
    fail("Expected LeadingCombiningMark")
  }
}

// =============================================================================
// Additional error condition tests
// =============================================================================

///|
test "error: domain too long" {
  // Create a domain > 253 characters
  let long_label = "a".repeat(50)
  let domain = long_label +
    "." +
    long_label +
    "." +
    long_label +
    "." +
    long_label +
    "." +
    long_label +
    ".com"
  let result = to_ascii_result(domain)
  guard result is Err(@idna.DomainTooLong) else {
    fail("Expected DomainTooLong")
  }
}

///|
test "error: empty domain" {
  let result = to_ascii_result("")
  guard result is Err(@idna.EmptyLabel) else { fail("Expected EmptyLabel") }
}

///|
test "error: only separator" {
  // Just a dot creates empty labels
  let result = to_ascii_result(".")
  guard result is Err(@idna.EmptyLabel) else { fail("Expected EmptyLabel") }
}

///|
test "error: trailing dot creates empty label" {
  let result = to_ascii_result("example.com.")
  guard result is Err(@idna.EmptyLabel) else { fail("Expected EmptyLabel") }
}

///|
test "error: hyphens at positions 3 and 4" {
  // "ab--cd" has hyphens at positions 3 and 4 (like ACE prefix pattern)
  let result = to_ascii_result("ab--cd.com", check_hyphens=true)
  guard result is Err(@idna.InvalidHyphen) else {
    fail("Expected InvalidHyphen")
  }
}

///|
test "error: disallowed replacement character" {
  // U+FFFD (Replacement Character) is disallowed in IDNA
  let result = to_ascii_result("exam\u{FFFD}ple.com")
  assert_true(result is Err(_))
}

///|
test "error: disallowed private use character" {
  // U+E000 is private use area - disallowed
  let result = to_ascii_result("exam\u{E000}ple.com")
  assert_true(result is Err(_))
}

// =============================================================================
// Label separator tests
// =============================================================================

///|
test "separator: halfwidth ideographic full stop" {
  // U+FF61 Halfwidth Ideographic Full Stop
  inspect(to_ascii("example\u{FF61}com"), content="example.com")
}

///|
test "separator: all four separators" {
  // Test all four label separators in one domain
  // U+002E (.), U+3002 (。), U+FF0E (．), U+FF61 (｡)
  let result = to_ascii(
    "a\u{002E}b\u{3002}c\u{FF0E}d\u{FF61}e",
    use_std3_ascii_rules=false,
    check_hyphens=false,
  )
  inspect(result, content="a.b.c.d.e")
}

// =============================================================================
// Mapping edge cases
// =============================================================================

///|
test "mapping: multiple ignored characters" {
  // Multiple soft hyphens should all be removed
  inspect(
    to_ascii("e\u{00AD}x\u{00AD}a\u{00AD}m\u{00AD}p\u{00AD}l\u{00AD}e.com"),
    content="example.com",
  )
}

///|
test "mapping: fullwidth to halfwidth" {
  // Fullwidth Latin letters map to ASCII
  // U+FF21 (Ａ) maps to U+0061 (a)
  inspect(to_ascii("\u{FF21}\u{FF22}\u{FF23}.com"), content="abc.com")
}

///|
test "mapping: Greek case folding" {
  // Greek capital letters are case-folded to lowercase
  // ΛΟΓΟΣ -> λογοσ (all lowercase sigma, not final sigma)
  let result = to_ascii("ΛΟΓΟΣ.com", check_bidi=false)
  inspect(result, content="xn--oxapmbu.com")
}

// =============================================================================
// Unicode script mixing tests
// =============================================================================

///|
test "scripts: Cyrillic domain" {
  let result = to_ascii("москва.рф")
  assert_true(result.has_prefix("xn--"))
  assert_true(result.contains("."))
}

///|
test "scripts: Thai domain" {
  let result = to_ascii("ไทย.th", check_bidi=false)
  assert_true(result.has_prefix("xn--"))
}

///|
test "scripts: Arabic domain with digits" {
  // Arabic with Arabic-Indic digits
  let result = to_ascii(
    "مثال\u{0661}\u{0662}\u{0663}.com",
    check_bidi=false,
  )
  assert_true(result.has_prefix("xn--"))
}
