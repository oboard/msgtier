///|
/// N0: Bracket Pair Processing
///
/// This rule handles matching bracket pairs according to UAX #9.
/// It uses the Bidi_Paired_Bracket property to find bracket pairs
/// and resolves their types based on context.

///|
/// Resolve bracket pairs within an isolating run sequence
fn resolve_bracket_pairs(
  chars : Array[Char],
  types : Array[@bidi_data.BidiClass],
  _levels : Array[Int],
  seq : IsolatingRunSequence,
) -> Unit {
  let indices = seq.indices
  if indices.length() == 0 {
    return
  }

  // Find bracket pairs in the sequence
  let pairs = find_bracket_pairs(chars, types, indices)
  if pairs.length() == 0 {
    return
  }

  // Get embedding direction
  let embedding_direction : @bidi_data.BidiClass = if seq.level % 2 == 0 {
    @bidi_data.BidiClass::L
  } else {
    @bidi_data.BidiClass::R
  }

  // Process each pair
  for pair in pairs {
    let open_idx = pair.0
    let close_idx = pair.1

    // N0b: Inspect types inside the bracket pair
    // Look for strong types inside
    let mut found_opposite = false
    let mut found_embedding = false
    for i = 0; i < indices.length(); i = i + 1 {
      let idx = indices[i]
      if idx <= open_idx || idx >= close_idx {
        continue
      }
      let bc = types[idx]
      match bc {
        L =>
          if embedding_direction == @bidi_data.BidiClass::R {
            found_opposite = true
          } else {
            found_embedding = true
          }
        R =>
          if embedding_direction == @bidi_data.BidiClass::L {
            found_opposite = true
          } else {
            found_embedding = true
          }
        EN | AN =>
          // EN and AN are treated as R for bracket matching
          if embedding_direction == @bidi_data.BidiClass::L {
            found_opposite = true
          } else {
            found_embedding = true
          }
        _ => ()
      }
    }

    // N0c: Determine bracket type
    if found_embedding {
      // Set both brackets to embedding direction
      types[open_idx] = embedding_direction
      types[close_idx] = embedding_direction
    } else if found_opposite {
      // N0c2: Look for strong type before the opening bracket
      // in the same direction as the embedding
      let mut context_type = seq.sos
      for i = 0; i < indices.length(); i = i + 1 {
        let idx = indices[i]
        if idx >= open_idx {
          break
        }
        let bc = types[idx]
        match bc {
          L | R => context_type = bc
          EN | AN => context_type = @bidi_data.BidiClass::R // EN/AN act as R
          _ => ()
        }
      }
      if context_type == embedding_direction {
        // Set brackets to embedding direction
        types[open_idx] = embedding_direction
        types[close_idx] = embedding_direction
      } else {
        // N0c2: Set brackets to opposite direction
        let opposite : @bidi_data.BidiClass = if embedding_direction ==
          @bidi_data.BidiClass::L {
          @bidi_data.BidiClass::R
        } else {
          @bidi_data.BidiClass::L
        }
        types[open_idx] = opposite
        types[close_idx] = opposite
      }
    }
    // If neither found_embedding nor found_opposite, leave brackets as ON
  }
}

///|
/// Find all bracket pairs in an isolating run sequence
/// Returns list of (open_char_idx, close_char_idx) sorted by open position
fn find_bracket_pairs(
  chars : Array[Char],
  types : Array[@bidi_data.BidiClass],
  indices : Array[Int],
) -> Array[(Int, Int)] {
  let pairs : Array[(Int, Int)] = []

  // Stack of (opening_bracket_char, char_index, sequence_position)
  let stack : Array[(Char, Int, Int)] = []
  let mut overflow = false
  for i = 0; i < indices.length(); i = i + 1 {
    let idx = indices[i]
    let c = chars[idx]

    // Only consider brackets that are ON type (after weak resolution)
    let bc = types[idx]
    if bc != @bidi_data.BidiClass::ON {
      continue
    }
    let bracket_type = @bidi_data.bracket_type(c)
    match bracket_type {
      Open =>
        // Push to stack
        if stack.length() < 63 { // BD16 limit
          stack.push((c, idx, i))
        } else {
          overflow = true
          break
        }
      Close =>
        // Find matching opening bracket
        match @bidi_data.paired_bracket(c) {
          Some(matching_open) => {
            // Search stack from top for matching open bracket
            let mut found = -1
            for j = stack.length() - 1; j >= 0; j = j - 1 {
              if canonical_bracket(stack[j].0) ==
                canonical_bracket(matching_open) {
                found = j
                break
              }
              // Also check canonical equivalents
              // (simplified - just check direct match)
            }
            if found >= 0 {
              let open_entry = stack[found]
              pairs.push((open_entry.1, idx))
              // Remove found entry and everything above it
              while stack.length() > found {
                let _ = stack.pop()
              }
            }
          }
          None => ()
        }
      None => ()
    }
  }

  if overflow {
    return []
  }

  // Sort pairs by opening position
  pairs.sort_by(fn(a, b) { a.0 - b.0 })
  pairs
}

///|
/// Map bracket characters to their canonical equivalents for matching.
fn canonical_bracket(c : Char) -> Char {
  match c {
    '\u{2329}' => '\u{3008}'
    '\u{232A}' => '\u{3009}'
    _ => c
  }
}
