///|
/// Unicode Normalization Forms (UAX #15)
///
/// This module implements the four Unicode normalization forms:
/// - NFD: Canonical Decomposition
/// - NFC: Canonical Decomposition followed by Canonical Composition
/// - NFKD: Compatibility Decomposition
/// - NFKC: Compatibility Decomposition followed by Canonical Composition

///|
/// Normalization form enumeration
pub(all) enum NormalizationForm {
  NFD // Canonical Decomposition
  NFC // Canonical Decomposition + Composition
  NFKD // Compatibility Decomposition
  NFKC // Compatibility Decomposition + Composition
} derive(Eq)

///|
pub impl Show for NormalizationForm with fn output(self, logger) {
  match self {
    NFD => logger.write_string("NFD")
    NFC => logger.write_string("NFC")
    NFKD => logger.write_string("NFKD")
    NFKC => logger.write_string("NFKC")
  }
}

///|
/// Convert array of characters to string
fn chars_to_string(chars : Array[Char]) -> String {
  let sb = StringBuilder::new()
  for c in chars {
    sb.write_char(c)
  }
  sb.to_string()
}

///|
/// Normalize a string to NFD (Canonical Decomposition)
///
/// Characters are decomposed to their canonical equivalents and
/// combining marks are reordered by Canonical Combining Class.
pub fn nfd(s : String) -> String {
  let chars = decompose_string(s, compatibility=false)
  canonical_order(chars)
  chars_to_string(chars)
}

///|
/// Normalize a string to NFC (Canonical Decomposition + Composition)
///
/// Characters are first decomposed canonically, reordered, then
/// recomposed using canonical composition rules.
/// This is the most commonly used normalization form.
pub fn nfc(s : String) -> String {
  let chars = decompose_string(s, compatibility=false)
  canonical_order(chars)
  let composed = canonical_compose(chars)
  chars_to_string(composed)
}

///|
/// Normalize a string to NFKD (Compatibility Decomposition)
///
/// Characters are decomposed to their compatibility equivalents
/// (including formatting variants like superscripts, fractions, etc.)
/// and combining marks are reordered.
pub fn nfkd(s : String) -> String {
  let chars = decompose_string(s, compatibility=true)
  canonical_order(chars)
  chars_to_string(chars)
}

///|
/// Normalize a string to NFKC (Compatibility Decomposition + Composition)
///
/// Characters are decomposed to compatibility equivalents, reordered,
/// then recomposed. Often used for identifier comparison.
pub fn nfkc(s : String) -> String {
  let chars = decompose_string(s, compatibility=true)
  canonical_order(chars)
  let composed = canonical_compose(chars)
  chars_to_string(composed)
}

///|
/// Normalize a string to the specified form
pub fn normalize(s : String, form : NormalizationForm) -> String {
  match form {
    NFD => nfd(s)
    NFC => nfc(s)
    NFKD => nfkd(s)
    NFKC => nfkc(s)
  }
}

///|
/// Check if a string is in the specified normalization form
pub fn is_normalized(s : String, form : NormalizationForm) -> Bool {
  normalize(s, form) == s
}
