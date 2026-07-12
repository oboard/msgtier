///|
/// Get the simple uppercase mapping for a character
/// Returns the character itself if no mapping exists
pub fn to_simple_uppercase(c : Char) -> Char {
  @ucd_data.lookup_simple_uppercase(c)
}

///|
/// Get the simple lowercase mapping for a character
/// Returns the character itself if no mapping exists
pub fn to_simple_lowercase(c : Char) -> Char {
  @ucd_data.lookup_simple_lowercase(c)
}

///|
/// Get the simple titlecase mapping for a character
/// Returns the character itself if no mapping exists
pub fn to_simple_titlecase(c : Char) -> Char {
  @ucd_data.lookup_simple_titlecase(c)
}

///|
/// Get the full uppercase mapping for a character
/// Returns a String containing one or more uppercase characters
/// For example, 'ß' (U+00DF) maps to "SS", and 'ﬃ' (U+FB03) maps to "FFI"
pub fn to_uppercase(c : Char) -> String {
  match @ucd_data.lookup_full_uppercase(c) {
    Some(chars) => String::from_array(chars)
    None => c.to_string()
  }
}

///|
/// Get the full lowercase mapping for a character
/// Returns a String containing one or more lowercase characters
/// For example, 'İ' (U+0130) maps to "i\u{0307}" (i with combining dot above)
pub fn to_lowercase(c : Char) -> String {
  match @ucd_data.lookup_full_lowercase(c) {
    Some(chars) => String::from_array(chars)
    None => c.to_string()
  }
}

///|
/// Get the full titlecase mapping for a character
/// Returns a String containing one or more titlecase characters
/// For example, 'ß' (U+00DF) maps to "Ss", and 'ﬃ' (U+FB03) maps to "Ffi"
pub fn to_titlecase(c : Char) -> String {
  match @ucd_data.lookup_full_titlecase(c) {
    Some(chars) => String::from_array(chars)
    None => c.to_string()
  }
}
