///|
/// IDNA label validation (UTS #46 Section 4.1)

///|
/// Validate a single label according to UTS #46 validity criteria
fn validate_label(
  label : String,
  use_std3_ascii_rules~ : Bool,
  check_hyphens~ : Bool,
  check_bidi~ : Bool,
  check_joiners~ : Bool,
) -> Unit raise IdnaError {
  // Empty labels should raise an error - they indicate either intentional empty
  // labels (like trailing dots) or labels that became empty after IDNA mapping
  // (like soft hyphen U+00AD). The caller can catch EmptyLabel and decide
  // whether to allow it based on context.
  if label.length() == 0 {
    raise EmptyLabel
  }
  let chars = label_to_chars(label)

  // Check 1: Must be NFC normalized
  if !@normalization.is_normalized(label, @normalization.NFC) {
    raise InvalidLabel(label)
  }

  // Check 2 & 3: Hyphen restrictions (when check_hyphens)
  if check_hyphens {
    validate_hyphens(label, chars)
  }

  // Check 4: No U+002E (full stop) within label - handled by label splitting

  // Check 5: No leading combining marks
  if chars.length() > 0 {
    let first_c = chars[0]
    if is_combining_mark(first_c) {
      raise LeadingCombiningMark
    }
  }

  // Check 6: All characters must have valid status
  for c in chars {
    validate_char_status(c, use_std3_ascii_rules)
  }

  // Check 7: ContextJ rules (when check_joiners)
  if check_joiners {
    validate_contextj(chars)
  }

  // Check 8: Bidi rules (when check_bidi)
  if check_bidi {
    validate_bidi(chars)
  }
}

///|
/// Convert a label string to array of characters
fn label_to_chars(label : String) -> Array[Char] {
  let result : Array[Char] = []
  for c in label {
    result.push(c)
  }
  result
}

///|
/// Validate hyphen restrictions
fn validate_hyphens(
  _label : String,
  chars : Array[Char],
) -> Unit raise IdnaError {
  // Cannot start or end with hyphen
  if chars.length() > 0 {
    if chars[0] == '-' || chars[chars.length() - 1] == '-' {
      raise InvalidHyphen
    }
  }

  // Cannot have hyphens at positions 3 and 4 (third and fourth characters)
  // This catches things like "xn--" in non-ACE context
  if chars.length() >= 4 {
    if chars[2] == '-' && chars[3] == '-' {
      raise InvalidHyphen
    }
  }
}

///|
/// Check if a character is a combining mark (General_Category = Mn, Mc, or Me)
/// This is used for the IDNA "no leading combining mark" validation (V5/V6)
fn is_combining_mark(c : Char) -> Bool {
  @ucd.is_mark(c)
}

///|
/// Check if an ASCII character is an LDH character (Letter, Digit, Hyphen)
/// This implements STD3 ASCII rules from RFC 952/1123
fn is_ldh_ascii(c : Char) -> Bool {
  // ASCII lowercase letters (a-z)
  (c >= 'a' && c <= 'z') ||
  // ASCII uppercase letters (A-Z) - should be mapped to lowercase already
  (c >= 'A' && c <= 'Z') ||
  // ASCII digits (0-9)
  (c >= '0' && c <= '9') ||
  // Hyphen-minus
  c == '-'
}

///|
/// Validate that a character has an acceptable IDNA status
fn validate_char_status(
  c : Char,
  use_std3_ascii_rules : Bool,
) -> Unit raise IdnaError {
  // STD3 ASCII rules: only LDH characters allowed in ASCII range
  // This check is separate from IdnaMappingTable.txt which marks
  // these characters as "valid" but they should be rejected under STD3
  if use_std3_ascii_rules && c.to_int() < 0x80 && !is_ldh_ascii(c) {
    raise DisallowedCodePoint(cp=c.to_int())
  }
  let (status, _) = @idna_data.lookup_idna_mapping(c)
  match status {
    @idna_data.Valid | @idna_data.Deviation =>
      // OK
      ()
    @idna_data.Mapped | @idna_data.Ignored =>
      // These should have been processed in the mapping step
      // If we see them here, something went wrong
      raise DisallowedCodePoint(cp=c.to_int())
    @idna_data.Disallowed => raise DisallowedCodePoint(cp=c.to_int())
    @idna_data.DisallowedSTD3Valid =>
      if use_std3_ascii_rules {
        raise DisallowedCodePoint(cp=c.to_int())
      }
    // Otherwise OK
    @idna_data.DisallowedSTD3Mapped =>
      if use_std3_ascii_rules {
        raise DisallowedCodePoint(cp=c.to_int())
      }
    // Otherwise should have been mapped
  }
}

///|
/// Validate ContextJ rules for ZWNJ (U+200C) and ZWJ (U+200D)
fn validate_contextj(chars : Array[Char]) -> Unit raise IdnaError {
  for i, c in chars {
    if c == '\u{200C}' {
      // ZWNJ: Zero Width Non-Joiner
      if !is_valid_zwnj_context(chars, i) {
        raise InvalidJoiner
      }
    } else if c == '\u{200D}' {
      // ZWJ: Zero Width Joiner
      if !is_valid_zwj_context(chars, i) {
        raise InvalidJoiner
      }
    }
  }
}

///|
/// Check if ZWNJ is in a valid context
/// Valid if:
/// - There is a combining Virama (U+094D, etc.) before, OR
/// - Surrounded by appropriate joining characters
fn is_valid_zwnj_context(chars : Array[Char], pos : Int) -> Bool {
  // Rule 1: After a Virama (e.g., for Indic scripts)
  if pos > 0 && is_virama(chars[pos - 1]) {
    return true
  }

  // Rule 2: Between joining characters
  // Look for L or D type before, and R or D type after
  if has_left_joining_before(chars, pos) && has_right_joining_after(chars, pos) {
    return true
  }
  false
}

///|
/// Check if ZWJ is in a valid context
/// Valid if preceded by a Virama
fn is_valid_zwj_context(chars : Array[Char], pos : Int) -> Bool {
  // ZWJ is valid if preceded by a combining Virama
  pos > 0 && is_virama(chars[pos - 1])
}

///|
/// Check if a character is a Virama (combining class 9)
fn is_virama(c : Char) -> Bool {
  @ucd.lookup_ccc(c) == 9
}

///|
/// Check if there's a left-joining or dual-joining character before position
fn has_left_joining_before(chars : Array[Char], pos : Int) -> Bool {
  for i = pos - 1; i >= 0; i = i - 1 {
    let jt = @idna_data.lookup_joining_type(chars[i])
    match jt {
      @idna_data.LeftJoining | @idna_data.DualJoining => return true
      @idna_data.Transparent => continue
      _ => return false
    }
  }
  false
}

///|
/// Check if there's a right-joining or dual-joining character after position
fn has_right_joining_after(chars : Array[Char], pos : Int) -> Bool {
  for i = pos + 1; i < chars.length(); i = i + 1 {
    let jt = @idna_data.lookup_joining_type(chars[i])
    match jt {
      @idna_data.RightJoining | @idna_data.DualJoining => return true
      @idna_data.Transparent => continue
      _ => return false
    }
  }
  false
}

///|
/// Validate Bidi rules (RFC 5893) for a single label
/// Note: For proper RFC 5893 compliance, use validate_domain_bidi() at domain level
fn validate_bidi(chars : Array[Char]) -> Unit raise IdnaError {
  if chars.length() == 0 {
    return
  }

  // Determine if this is an RTL label
  let is_rtl_label = is_rtl_label_check(chars)
  if is_rtl_label {
    validate_rtl_label(chars)
  } else {
    validate_ltr_label(chars)
  }
}

///|
/// Validate Bidi rules (RFC 5893) for an entire domain
/// RFC 5893 requires domain-level checking: when ANY label is RTL,
/// all labels must follow stricter rules.
fn validate_domain_bidi(labels : Array[String]) -> Unit raise IdnaError {
  // Check if domain contains any RTL labels
  let mut has_rtl_label = false
  for label in labels {
    if label.length() > 0 {
      let chars = label_to_chars(label)
      if is_rtl_label_check(chars) {
        has_rtl_label = true
        break
      }
    }
  }
  if !has_rtl_label {
    // Not a Bidi domain name - no Bidi validation needed per UTS #46
    // "If CheckBidi, and if the domain name is a Bidi domain name, then..."
    return
  }

  // RTL domain: stricter rules apply to all labels
  for label in labels {
    if label.length() == 0 {
      continue
    }
    let chars = label_to_chars(label)
    let is_rtl = is_rtl_label_check(chars)
    if is_rtl {
      validate_rtl_label(chars)
    } else {
      // LTR label in RTL domain - must start with L (stricter rule)
      validate_ltr_label_in_rtl_domain(chars)
    }
  }
}

///|
/// Validate LTR label that appears in an RTL domain
/// Stricter than regular LTR validation: first char must be L (not EN/ON/etc.)
fn validate_ltr_label_in_rtl_domain(
  chars : Array[Char],
) -> Unit raise IdnaError {
  if chars.length() == 0 {
    return
  }

  // In RTL domain, LTR labels must start with L (not EN, ES, etc.)
  // This is stricter than pure LTR domain rules
  let first_bc = @bidi.lookup_bidi_class(chars[0])
  match first_bc {
    @bidi.L => ()
    _ => raise InvalidBidi // B1 - first char must be L in RTL domain context
  }

  // Track last non-NSM for ending check
  let mut last_non_nsm_bc = first_bc

  // Same allowed classes as regular LTR, but no R/AL/AN
  for c in chars {
    let bc = @bidi.lookup_bidi_class(c)
    match bc {
      @bidi.L
      | @bidi.EN
      | @bidi.ES
      | @bidi.CS
      | @bidi.ET
      | @bidi.ON
      | @bidi.BN
      | @bidi.NSM => if !(bc is @bidi.NSM) { last_non_nsm_bc = bc }
      @bidi.R | @bidi.AL | @bidi.AN => raise InvalidBidi
      _ => ()
    }
  }

  // Rule 6 (B6): Last non-NSM character must be L or EN
  match last_non_nsm_bc {
    @bidi.L | @bidi.EN => ()
    _ => raise InvalidBidi // B6 - ending violation
  }
}

///|
/// Check if label is RTL (contains R, AL, or AN characters)
fn is_rtl_label_check(chars : Array[Char]) -> Bool {
  for c in chars {
    let bc = @bidi.lookup_bidi_class(c)
    match bc {
      @bidi.R | @bidi.AL | @bidi.AN => return true
      _ => continue
    }
  }
  false
}

///|
/// Validate an RTL label according to RFC 5893
fn validate_rtl_label(chars : Array[Char]) -> Unit raise IdnaError {
  // Rule 1 (B1): First character must be R or AL
  let first_bc = @bidi.lookup_bidi_class(chars[0])
  match first_bc {
    @bidi.R | @bidi.AL => ()
    _ => raise InvalidBidi
  }

  // Track last non-NSM character for ending check (B3)
  // and whether EN/AN appear (B4)
  let mut last_non_nsm_bc : @bidi.BidiClass = first_bc
  let mut has_en = false
  let mut has_an = false
  for c in chars {
    let bc = @bidi.lookup_bidi_class(c)
    match bc {
      @bidi.R
      | @bidi.AL
      | @bidi.AN
      | @bidi.EN
      | @bidi.ES
      | @bidi.CS
      | @bidi.ET
      | @bidi.ON
      | @bidi.BN
      | @bidi.NSM => {
        // Rule 2 (B2): Allowed in RTL label
        if !(bc is @bidi.NSM) {
          last_non_nsm_bc = bc
        }
        if bc is @bidi.EN {
          has_en = true
        }
        if bc is @bidi.AN {
          has_an = true
        }
      }
      @bidi.L => raise InvalidBidi // B2 - L not allowed in RTL label
      _ => ()
    }
  }

  // Rule 3 (B3): Last non-NSM character must be R, AL, EN, or AN
  match last_non_nsm_bc {
    @bidi.R | @bidi.AL | @bidi.EN | @bidi.AN => ()
    _ => raise InvalidBidi
  }

  // Rule 4 (B4): EN and AN cannot both appear
  if has_en && has_an {
    raise InvalidBidi
  }
}

///|
/// Validate an LTR label according to RFC 5893
fn validate_ltr_label(chars : Array[Char]) -> Unit raise IdnaError {
  if chars.length() == 0 {
    return
  }

  // Rule 5 (B5): First character must be L
  // (Relaxed for pure ASCII/neutral labels in pure LTR domains)
  let first_bc = @bidi.lookup_bidi_class(chars[0])
  match first_bc {
    @bidi.L => ()
    // Allow pure ASCII/neutral labels (existing behavior for pure LTR domains)
    @bidi.EN
    | @bidi.ES
    | @bidi.CS
    | @bidi.ET
    | @bidi.ON
    | @bidi.BN
    | @bidi.NSM => ()
    _ => raise InvalidBidi
  }

  // Track last non-NSM character for ending check (B6)
  let mut last_non_nsm_bc = first_bc

  // Rule 5: Only certain Bidi classes allowed in LTR label
  for c in chars {
    let bc = @bidi.lookup_bidi_class(c)
    match bc {
      @bidi.L
      | @bidi.EN
      | @bidi.ES
      | @bidi.CS
      | @bidi.ET
      | @bidi.ON
      | @bidi.BN
      | @bidi.NSM =>
        // Allowed in LTR label
        if !(bc is @bidi.NSM) {
          last_non_nsm_bc = bc
        }
      @bidi.R | @bidi.AL | @bidi.AN => raise InvalidBidi // RTL chars not allowed
      _ => ()
    }
  }

  // Rule 6 (B6): Last non-NSM character must be L or EN
  match last_non_nsm_bc {
    @bidi.L | @bidi.EN => ()
    _ => raise InvalidBidi // B6 - ending violation
  }
}
