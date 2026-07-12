///|
/// Normalization-specific fuzz utilities

///|
/// Convert string to array of characters
fn string_to_chars(s : String) -> Array[Char] {
  let result : Array[Char] = []
  for c in s {
    result.push(c)
  }
  result
}

///|
/// Check if combining marks in a string are sorted by CCC
pub fn ccc_is_sorted(s : String) -> Bool {
  let chars = string_to_chars(s)
  for i = 0, last_ccc = 0, in_combining = false; i < chars.length(); {
    let c = chars[i]
    let ccc = @ucd.lookup_ccc(c)
    if ccc == 0 {
      // Starter - reset
      continue i + 1, 0, false
    } else {
      // Combining mark
      if in_combining && ccc < last_ccc {
        break false // Not sorted
      }
      continue i + 1, ccc, true
    }
  } nobreak {
    true
  }
}
