///|
/// Decomposition algorithm for Unicode normalization
/// Implements recursive decomposition for NFD/NFKD

///|
/// Recursively decompose a single character
/// Returns array of characters in fully decomposed form
fn decompose_char(c : Char, compatibility~ : Bool) -> Array[Char] {
  // Handle Hangul syllables algorithmically
  if is_hangul_syllable(c) {
    return decompose_hangul(c)
  }

  // Look up decomposition mapping
  let mapping : Array[Char]? = if compatibility {
    // For compatibility, first try compat decomposition, then canonical
    match @ucd.get_compat_decomposition(c) {
      Some(d) => Some(d)
      None => @ucd.get_canonical_decomposition(c)
    }
  } else {
    @ucd.get_canonical_decomposition(c)
  }
  match mapping {
    None => [c] // No decomposition, return as-is
    Some(decomposed) => {
      // Recursively decompose each component
      let result : Array[Char] = []
      for d in decomposed {
        result.append(decompose_char(d, compatibility~))
      }
      result
    }
  }
}

///|
/// Decompose a string to array of characters
/// This is the first step for all normalization forms
fn decompose_string(s : String, compatibility~ : Bool) -> Array[Char] {
  let result : Array[Char] = []
  for c in s {
    result.append(decompose_char(c, compatibility~))
  }
  result
}
