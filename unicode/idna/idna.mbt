///|
/// IDNA (Internationalized Domain Names in Applications) processing
/// Implements UTS #46: Unicode IDNA Compatibility Processing
/// https://www.unicode.org/reports/tr46/

///|
/// Error types for IDNA processing
pub(all) suberror IdnaError {
  PunycodeError(@punycode.PunycodeError)
  DisallowedCodePoint(cp~ : Int)
  InvalidLabel(String)
  InvalidHyphen
  LabelTooLong
  DomainTooLong
  EmptyLabel
  InvalidBidi
  InvalidJoiner
  InvalidAcePrefix
  LeadingCombiningMark
}

///|
pub impl Show for IdnaError with fn output(self, logger) {
  match self {
    PunycodeError(error) => {
      logger.write_string("PunycodeError(")
      error.output(logger)
      logger.write_string(")")
    }
    DisallowedCodePoint(cp~) => {
      logger.write_string("DisallowedCodePoint(cp=")
      cp.output(logger)
      logger.write_string(")")
    }
    InvalidLabel(label) => {
      logger.write_string("InvalidLabel(")
      label.output(logger)
      logger.write_string(")")
    }
    InvalidHyphen => logger.write_string("InvalidHyphen")
    LabelTooLong => logger.write_string("LabelTooLong")
    DomainTooLong => logger.write_string("DomainTooLong")
    EmptyLabel => logger.write_string("EmptyLabel")
    InvalidBidi => logger.write_string("InvalidBidi")
    InvalidJoiner => logger.write_string("InvalidJoiner")
    InvalidAcePrefix => logger.write_string("InvalidAcePrefix")
    LeadingCombiningMark => logger.write_string("LeadingCombiningMark")
  }
}

///|
/// ACE prefix for Punycode labels
let ace_prefix : String = "xn--"

///|
/// Convert a domain name to ASCII (for DNS lookup)
/// This is the main entry point for IDNA ToASCII operation
pub fn to_ascii(
  domain : String,
  use_std3_ascii_rules? : Bool = true,
  check_hyphens? : Bool = true,
  check_bidi? : Bool = true,
  check_joiners? : Bool = true,
  verify_dns_length? : Bool = true,
) -> String raise IdnaError {
  // Process the domain (mapping, normalization, basic validation)
  // Note: Bidi is handled separately to support ACE-encoded inputs
  let processed = process_domain(
    domain,
    use_std3_ascii_rules~,
    check_hyphens~,
    check_bidi=false, // Domain-level bidi handled below after ACE decoding
    check_joiners~,
  )

  // Split into labels
  let labels = split_labels(processed)
  let label_count = labels.length()
  // A valid trailing dot requires at least 2 labels (e.g., "example.com." -> ["example", "com", ""])
  // A single empty label (from empty domain like "") is NOT a trailing dot
  let has_trailing_dot = label_count > 1 && labels[label_count - 1] == ""

  // For domain-level bidi validation, we need Unicode content of all labels
  // This requires decoding ACE labels first
  let unicode_labels : Array[String] = []
  let ascii_labels : Array[String] = []
  for i, label in labels {
    // Handle trailing empty label
    if i == label_count - 1 && has_trailing_dot {
      unicode_labels.push("")
      ascii_labels.push("")
      continue
    }
    if label.length() == 0 {
      // Empty label that's not a trailing dot - this is invalid
      // (could be from IDNA mapping like soft hyphen -> "", or ".." in domain)
      raise EmptyLabel
    }

    // Process label to get both Unicode and ASCII forms
    let (unicode_label, ascii_label) = process_label_for_ascii(
      label,
      use_std3_ascii_rules~,
      check_hyphens~,
      check_joiners~,
    )
    unicode_labels.push(unicode_label)
    ascii_labels.push(ascii_label)
  }

  // Domain-level bidi validation on Unicode labels
  if check_bidi {
    let labels_for_bidi = if has_trailing_dot {
      unicode_labels.iter().take(label_count - 1).collect()
    } else {
      unicode_labels
    }
    validate_domain_bidi(labels_for_bidi)
  }
  let result = ascii_labels.join(".")

  // Verify DNS length constraints
  if verify_dns_length {
    verify_dns_length_constraints(result, ascii_labels)
  }
  result
}

///|
/// Process a single label and return both Unicode and ASCII forms
/// Used by to_ascii to collect Unicode labels for domain-level bidi validation
fn process_label_for_ascii(
  label : String,
  use_std3_ascii_rules~ : Bool,
  check_hyphens~ : Bool,
  check_joiners~ : Bool,
) -> (String, String) raise IdnaError {
  if label.length() == 0 {
    return ("", "")
  }

  // Check if label has ACE prefix (xn--)
  if has_ace_prefix(label) {
    // Decode ACE label to get Unicode content
    let punycode_part = get_substring_after_prefix(label, 4)
    let decoded = @punycode.decode(punycode_part) catch {
      error => raise PunycodeError(error)
    }

    // Apply mapping and normalize
    let mapped = map_label(decoded, use_std3_ascii_rules~)
    let normalized = @normalization.nfc(mapped)

    // Validate the decoded label (without bidi - done at domain level)
    validate_label(
      normalized,
      use_std3_ascii_rules~,
      check_hyphens~,
      check_bidi=false, // Bidi done at domain level
      check_joiners~,
    )

    // Re-encode for roundtrip check
    let re_encoded = encode_label_to_ascii(normalized)

    // Roundtrip check (V7 error on mismatch)
    if re_encoded != label.to_lower() {
      raise InvalidAcePrefix
    }
    return (normalized, label.to_lower())
  }

  // Non-ACE label: just encode
  let ascii_label = encode_label_to_ascii(label)
  (label, ascii_label)
}

///|
/// Convert a domain name to Unicode (for display)
/// This is the main entry point for IDNA ToUnicode operation
pub fn to_unicode(
  domain : String,
  use_std3_ascii_rules? : Bool = true,
  check_hyphens? : Bool = true,
  check_bidi? : Bool = true,
  check_joiners? : Bool = true,
) -> String raise IdnaError {
  // Split into labels first (before mapping, to handle Punycode)
  let labels = split_labels(domain)
  let label_count = labels.length()
  // A valid trailing dot requires at least 2 labels (e.g., "example.com." -> ["example", "com", ""])
  // A single empty label (from empty domain like "") is NOT a trailing dot
  let has_trailing_dot = label_count > 1 && labels[label_count - 1] == ""
  let unicode_labels : Array[String] = []
  for i, label in labels {
    // Skip processing for trailing empty label (trailing dot)
    if i == label_count - 1 && has_trailing_dot {
      unicode_labels.push("")
      continue
    }
    if label.length() == 0 {
      // Empty label that's not a trailing dot - this is invalid
      raise EmptyLabel
    }
    let unicode_label = label_to_unicode(
      label,
      use_std3_ascii_rules~,
      check_hyphens~,
      check_bidi~,
      check_joiners~,
    )
    unicode_labels.push(unicode_label)
  }
  unicode_labels.join(".")
}

///|
/// Encode a label to ASCII (Punycode if needed), without ACE validation
fn encode_label_to_ascii(label : String) -> String raise IdnaError {
  // Check if label is already ASCII
  let mut all_ascii = true
  for c in label {
    if c.to_int() >= 0x80 {
      all_ascii = false
      break
    }
  }
  if all_ascii {
    // Already ASCII, return as-is (lowercased)
    label.to_lower()
  } else {
    // Encode to Punycode
    let encoded = @punycode.encode(label.to_lower()) catch {
      error => raise PunycodeError(error)
    }
    ace_prefix + encoded
  }
}

///|
/// Convert a single label from Punycode to Unicode if needed
fn label_to_unicode(
  label : String,
  use_std3_ascii_rules~ : Bool,
  check_hyphens~ : Bool,
  check_bidi~ : Bool,
  check_joiners~ : Bool,
) -> String raise IdnaError {
  let unicode_label = if has_ace_prefix(label) {
    // Decode Punycode - skip "xn--" prefix
    let punycode_part = get_substring_after_prefix(label, 4)
    let decoded = @punycode.decode(punycode_part) catch {
      error => raise PunycodeError(error)
    }
    decoded
  } else {
    label
  }

  // Apply mapping and normalize
  let processed = map_label(unicode_label, use_std3_ascii_rules~)
  let normalized = @normalization.nfc(processed)

  // Validate the label
  validate_label(
    normalized,
    use_std3_ascii_rules~,
    check_hyphens~,
    check_bidi~,
    check_joiners~,
  )
  normalized
}

///|
/// Check if a label has the ACE prefix "xn--"
fn has_ace_prefix(label : String) -> Bool {
  label.to_lower().has_prefix("xn--")
}

///|
/// Get substring after a given prefix length (safe version)
fn get_substring_after_prefix(s : String, prefix_len : Int) -> String {
  let result = StringBuilder::new()
  let mut i = 0
  for c in s {
    if i >= prefix_len {
      result.write_char(c)
    }
    i = i + 1
  }
  result.to_string()
}

///|
/// Verify DNS length constraints
fn verify_dns_length_constraints(
  domain : String,
  labels : Array[String],
) -> Unit raise IdnaError {
  // Each label must be 1-63 characters
  // Empty labels are not allowed (including trailing dots in DNS)
  for label in labels {
    if label.length() == 0 {
      raise EmptyLabel
    }
    if label.length() > 63 {
      raise LabelTooLong
    }
  }

  // Total domain name must be at most 253 characters
  if domain.length() > 253 {
    raise DomainTooLong
  }
}
