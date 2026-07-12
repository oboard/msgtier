///|
test "general_category: ASCII letters" {
  // Uppercase letters
  inspect(general_category('A'), content="Lu")
  inspect(general_category('Z'), content="Lu")
  // Lowercase letters
  inspect(general_category('a'), content="Ll")
  inspect(general_category('z'), content="Ll")
}

///|
test "general_category: digits" {
  inspect(general_category('0'), content="Nd")
  inspect(general_category('9'), content="Nd")
}

///|
test "general_category: punctuation" {
  inspect(general_category('!'), content="Po")
  inspect(general_category('('), content="Ps")
  inspect(general_category(')'), content="Pe")
  inspect(general_category('-'), content="Pd")
}

///|
test "general_category: symbols" {
  inspect(general_category('$'), content="Sc")
  inspect(general_category('+'), content="Sm")
  inspect(general_category('<'), content="Sm")
}

///|
test "general_category: control characters" {
  inspect(general_category('\u{00}'), content="Cc") // NUL
  inspect(general_category('\t'), content="Cc") // TAB
  inspect(general_category('\n'), content="Cc") // LF
  inspect(general_category('\r'), content="Cc") // CR
}

///|
test "general_category: space" {
  inspect(general_category(' '), content="Zs") // SPACE
}

///|
test "general_category: CJK ideographs" {
  inspect(general_category('\u{4E00}'), content="Lo") // First CJK Unified Ideograph
  inspect(general_category('\u{9FFF}'), content="Lo") // Last CJK Unified Ideograph (approx)
}

///|
test "general_category: marks" {
  inspect(general_category('\u{0300}'), content="Mn") // COMBINING GRAVE ACCENT
  inspect(general_category('\u{0301}'), content="Mn") // COMBINING ACUTE ACCENT
  inspect(general_category('\u{0903}'), content="Mc") // DEVANAGARI SIGN VISARGA
}

///|
test "general_category: private use" {
  inspect(general_category('\u{E000}'), content="Co") // Private Use Area start
}

///|
test "GeneralCategory::group" {
  // Letters
  assert_eq(general_category('A').group(), L)
  assert_eq(general_category('a').group(), L)
  // Numbers
  assert_eq(general_category('0').group(), N)
  assert_eq(general_category('9').group(), N)
  // Marks
  assert_eq(general_category('\u{0300}').group(), M) // COMBINING GRAVE ACCENT
  // Separators
  assert_eq(general_category(' ').group(), Z)
  // Punctuation
  assert_eq(general_category('!').group(), P)
  // Symbols
  assert_eq(general_category('$').group(), S)
  // Other
  assert_eq(general_category('\u{00}').group(), C) // NUL
}

///|
test "to_simple_uppercase: basic" {
  inspect(to_simple_uppercase('a'), content="A")
  inspect(to_simple_uppercase('z'), content="Z")
  inspect(to_simple_uppercase('A'), content="A") // unchanged
  inspect(to_simple_uppercase('0'), content="0") // unchanged
}

///|
test "to_simple_lowercase: basic" {
  inspect(to_simple_lowercase('A'), content="a")
  inspect(to_simple_lowercase('Z'), content="z")
  inspect(to_simple_lowercase('a'), content="a") // unchanged
  inspect(to_simple_lowercase('0'), content="0") // unchanged
}

///|
test "to_simple_titlecase: basic" {
  // For most characters, titlecase == uppercase
  inspect(to_simple_titlecase('a'), content="A")
  inspect(to_simple_titlecase('A'), content="A") // unchanged
}

///|
test "case mapping: Greek letters" {
  inspect(to_simple_uppercase('\u{03B1}'), content="Α") // alpha -> ALPHA
  inspect(to_simple_lowercase('\u{0391}'), content="α") // ALPHA -> alpha
}

///|
test "case mapping: German sharp s" {
  // LATIN SMALL LETTER SHARP S has simple uppercase to itself
  // (full uppercase is "SS" but simple mapping is same)
  inspect(to_simple_uppercase('\u{00DF}'), content="ß") // sharp s -> sharp s
}

///|
test "case mapping: roundtrip for ASCII" {
  // Test uppercase letters A-Z
  for i = 0; i < 26; i = i + 1 {
    let cp = 'A'.to_int() + i
    let c = cp.unsafe_to_char()
    let lower = to_simple_lowercase(c)
    let back_to_upper = to_simple_uppercase(lower)
    assert_eq(back_to_upper, c)
  }
  // Test lowercase letters a-z
  for i = 0; i < 26; i = i + 1 {
    let cp = 'a'.to_int() + i
    let c = cp.unsafe_to_char()
    let upper = to_simple_uppercase(c)
    let back_to_lower = to_simple_lowercase(upper)
    assert_eq(back_to_lower, c)
  }
}

///|
test "to_uppercase: German sharp s" {
  // LATIN SMALL LETTER SHARP S -> "SS"
  inspect(to_uppercase('\u{00DF}'), content="SS")
}

///|
test "to_uppercase: ligatures" {
  // LATIN SMALL LIGATURE FF -> "FF"
  inspect(to_uppercase('\u{FB00}'), content="FF")
  // LATIN SMALL LIGATURE FFI -> "FFI"
  inspect(to_uppercase('\u{FB03}'), content="FFI")
  // LATIN SMALL LIGATURE FFL -> "FFL"
  inspect(to_uppercase('\u{FB04}'), content="FFL")
}

///|
test "to_titlecase: German sharp s" {
  // LATIN SMALL LETTER SHARP S -> "Ss"
  inspect(to_titlecase('\u{00DF}'), content="Ss")
}

///|
test "to_titlecase: ligatures" {
  // LATIN SMALL LIGATURE FF -> "Ff"
  inspect(to_titlecase('\u{FB00}'), content="Ff")
  // LATIN SMALL LIGATURE FFI -> "Ffi"
  inspect(to_titlecase('\u{FB03}'), content="Ffi")
}

///|
test "to_lowercase: I with dot above" {
  // LATIN CAPITAL LETTER I WITH DOT ABOVE -> "i" + combining dot above
  inspect(to_lowercase('\u{0130}'), content="i\u{0307}")
}

///|
test "full case: regular letters" {
  // Regular letters should go through simple mappings
  inspect(to_uppercase('a'), content="A")
  inspect(to_uppercase('z'), content="Z")
  inspect(to_lowercase('A'), content="a")
  inspect(to_lowercase('Z'), content="z")
  inspect(to_titlecase('a'), content="A")
}

///|
test "full case: no mapping returns identity" {
  // Characters without mappings return themselves
  inspect(to_uppercase('0'), content="0")
  inspect(to_lowercase('0'), content="0")
  inspect(to_titlecase('!'), content="!")
}
