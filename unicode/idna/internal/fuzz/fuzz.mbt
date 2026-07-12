///|
/// IDNA-specific fuzz testing utilities

///|
/// Check if a string contains only ASCII characters
pub fn is_ascii_string(s : String) -> Bool {
  for c in s {
    if c.to_int() >= 0x80 {
      return false
    }
  }
  true
}

///|
/// Generate a random domain-like string (labels separated by dots)
pub fn random_domain(rng : @random.Rand, max_labels? : Int = 3) -> String {
  let num_labels = rng.int(limit=max_labels) + 1
  let labels : Array[String] = []
  for _ in 0..<num_labels {
    let label = random_label(rng)
    labels.push(label)
  }
  labels.join(".")
}

///|
/// Generate a random label (no dots, reasonable length)
pub fn random_label(rng : @random.Rand) -> String {
  let len = rng.int(limit=15) + 1 // 1-15 chars to stay under 63 limit after encoding
  let sb = StringBuilder::new()
  for i in 0..<len {
    // Avoid leading combining marks and hyphens at boundaries
    let cp = if i == 0 || i == len - 1 {
      // Use safe characters at boundaries
      @base_fuzz.random_codepoint(rng, Ascii)
    } else {
      let choice = rng.int(limit=4)
      if choice == 0 {
        @base_fuzz.random_codepoint(rng, Ascii)
      } else if choice == 1 {
        @base_fuzz.random_codepoint(rng, LatinExtended)
      } else if choice == 2 {
        @base_fuzz.random_codepoint(rng, HangulSyllable)
      } else {
        @base_fuzz.random_codepoint(rng, Ascii)
      }
    }
    sb.write_char(cp)
  }
  sb.to_string()
}

///|
/// Generate an ASCII-only label
pub fn random_ascii_label(rng : @random.Rand) -> String {
  let len = rng.int(limit=15) + 1
  let sb = StringBuilder::new()
  for _ in 0..<len {
    let cp = @base_fuzz.random_codepoint(rng, Ascii)
    sb.write_char(cp)
  }
  sb.to_string()
}

///|
/// Generate a label with RTL (Arabic) characters
pub fn random_arabic_label(rng : @random.Rand) -> String {
  let len = rng.int(limit=10) + 1
  let sb = StringBuilder::new()
  for _ in 0..<len {
    let cp = @base_fuzz.random_codepoint(rng, ArabicRTL)
    sb.write_char(cp)
  }
  sb.to_string()
}

///|
/// Generate a label with RTL (Hebrew) characters
pub fn random_hebrew_label(rng : @random.Rand) -> String {
  let len = rng.int(limit=10) + 1
  let sb = StringBuilder::new()
  for _ in 0..<len {
    let cp = @base_fuzz.random_codepoint(rng, HebrewRTL)
    sb.write_char(cp)
  }
  sb.to_string()
}

///|
/// Generate a label with mixed LTR and RTL characters (invalid bidi)
pub fn random_mixed_bidi_label(rng : @random.Rand) -> String {
  let sb = StringBuilder::new()
  // Start with LTR
  sb.write_char(@base_fuzz.random_codepoint(rng, Ascii))
  // Add RTL in middle
  sb.write_char(@base_fuzz.random_codepoint(rng, ArabicRTL))
  // End with LTR
  sb.write_char(@base_fuzz.random_codepoint(rng, Ascii))
  sb.to_string()
}

///|
/// Generate a label with joiners (ZWNJ/ZWJ)
pub fn random_label_with_joiners(
  rng : @random.Rand,
  at_boundary~ : Bool,
) -> String {
  let sb = StringBuilder::new()
  if at_boundary {
    // Joiner at start - invalid
    sb.write_char(@base_fuzz.random_codepoint(rng, IdnaDeviation))
    sb.write_char(@base_fuzz.random_codepoint(rng, Ascii))
  } else {
    // Joiner in middle - may be valid depending on context
    sb.write_char(@base_fuzz.random_codepoint(rng, Ascii))
    sb.write_char(@base_fuzz.random_codepoint(rng, IdnaDeviation))
    sb.write_char(@base_fuzz.random_codepoint(rng, Ascii))
  }
  sb.to_string()
}

///|
/// Generate a label with ignored characters
pub fn random_label_with_ignored(rng : @random.Rand) -> String {
  let sb = StringBuilder::new()
  // Start with valid char
  sb.write_char(@base_fuzz.random_codepoint(rng, LatinExtended))
  // Add ignored character (soft hyphen, etc.)
  sb.write_char(@base_fuzz.random_codepoint(rng, IdnaIgnored))
  // End with valid char
  sb.write_char(@base_fuzz.random_codepoint(rng, LatinExtended))
  sb.to_string()
}

///|
/// Generate a label with mapped characters (fullwidth, uppercase)
pub fn random_label_with_mapped(rng : @random.Rand) -> String {
  let sb = StringBuilder::new()
  let len = rng.int(limit=5) + 1
  for _ in 0..<len {
    let cp = @base_fuzz.random_codepoint(rng, IdnaMapped)
    sb.write_char(cp)
  }
  sb.to_string()
}

///|
/// Generate a label starting with a combining mark
pub fn random_label_leading_combining(rng : @random.Rand) -> String {
  let sb = StringBuilder::new()
  // Start with combining mark - invalid
  sb.write_char(@base_fuzz.random_codepoint(rng, CombiningMark))
  // Add base character
  sb.write_char(@base_fuzz.random_codepoint(rng, Ascii))
  sb.to_string()
}

///|
/// Generate a long label (> 63 chars after encoding)
pub fn random_long_label(rng : @random.Rand) -> String {
  let sb = StringBuilder::new()
  // Generate 70+ characters
  for _ in 0..<70 {
    let cp = @base_fuzz.random_codepoint(rng, Ascii)
    sb.write_char(cp)
  }
  sb.to_string()
}

///|
/// Generate a label with disallowed characters
pub fn random_label_with_disallowed(rng : @random.Rand) -> String {
  let sb = StringBuilder::new()
  sb.write_char(@base_fuzz.random_codepoint(rng, Ascii))
  sb.write_char(@base_fuzz.random_codepoint(rng, IdnaDisallowed))
  sb.write_char(@base_fuzz.random_codepoint(rng, Ascii))
  sb.to_string()
}

///|
/// Generate a label starting/ending with hyphen
pub fn random_label_boundary_hyphen(
  rng : @random.Rand,
  at_start~ : Bool,
) -> String {
  let sb = StringBuilder::new()
  if at_start {
    sb.write_char('-')
    sb.write_char(@base_fuzz.random_codepoint(rng, Ascii))
    sb.write_char(@base_fuzz.random_codepoint(rng, Ascii))
  } else {
    sb.write_char(@base_fuzz.random_codepoint(rng, Ascii))
    sb.write_char(@base_fuzz.random_codepoint(rng, Ascii))
    sb.write_char('-')
  }
  sb.to_string()
}
