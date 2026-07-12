///|
/// Canonical Composition Algorithm
/// Composes adjacent starter + non-blocked combining marks into precomposed characters

///|
/// Try to compose two characters into one
/// Handles both Hangul and general composition
fn try_compose(first : Char, second : Char) -> Char? {
  // Try Hangul composition first (algorithmic, no table lookup)
  match try_compose_hangul(first, second) {
    Some(h) => return Some(h)
    None => ()
  }

  // Look up in composition table
  @ucd.lookup_composition(first, second)
}

///|
/// Compose a sequence of canonically ordered characters
/// This is the final step for NFC and NFKC
fn canonical_compose(chars : Array[Char]) -> Array[Char] {
  let len = chars.length()
  if len == 0 {
    return []
  }
  let result : Array[Char] = []
  result.push(chars[0])

  // Track the last starter position in result (-1 if no starter yet)
  let mut last_starter_idx = if @ucd.lookup_ccc(chars[0]) == 0 { 0 } else { -1 }

  // Track CCC of the last character we processed
  // Used to detect "blocked" combining marks
  let mut last_ccc = @ucd.lookup_ccc(chars[0])
  for i = 1; i < len; i = i + 1 {
    let c = chars[i]
    let ccc = @ucd.lookup_ccc(c)

    // A combining mark is "blocked" from composing with a starter if
    // there's an intervening combining mark with the same or higher CCC
    // (since marks are canonically ordered by CCC)
    //
    // We can compose if:
    // 1. There is a last starter (last_starter_idx >= 0)
    // 2. Either this is right after the starter (last_ccc == 0)
    //    OR this mark's CCC is greater than the previous mark's CCC
    let not_blocked = last_ccc == 0 || (ccc != 0 && last_ccc < ccc)
    if last_starter_idx >= 0 && not_blocked {
      let starter = result[last_starter_idx]
      match try_compose(starter, c) {
        Some(composed) => {
          // Successfully composed - update the starter in result
          result[last_starter_idx] = composed
          // The composed character is still a starter, don't update last_ccc
          // This allows further composition with subsequent marks
          continue i + 1
        }
        None => ()
      }
    }

    // Could not compose, add to result
    result.push(c)
    if ccc == 0 {
      // This is a new starter
      last_starter_idx = result.length() - 1
      last_ccc = 0
    } else {
      // This is a combining mark, update last_ccc
      last_ccc = ccc
    }
  }
  result
}
