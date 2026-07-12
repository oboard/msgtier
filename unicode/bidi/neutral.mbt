///|
/// N1-N2: Neutral Type Resolution
///
/// These rules resolve neutral types (B, S, WS, ON, FSI, LRI, RLI, PDI)
/// after bracket pair resolution.

///|
/// Resolve neutral types within an isolating run sequence
fn resolve_neutral_types(
  types : Array[@bidi_data.BidiClass],
  _levels : Array[Int],
  seq : IsolatingRunSequence,
) -> Unit {
  let indices = seq.indices
  if indices.length() == 0 {
    return
  }

  // Find runs of neutrals and resolve them
  let mut i = 0
  while i < indices.length() {
    let idx = indices[i]
    let bc = types[idx]
    if is_neutral_or_isolate(bc) {
      // Found start of a neutral run
      let run_start = i

      // Find end of neutral run
      let mut run_end = i
      while run_end + 1 < indices.length() {
        let next_bc = types[indices[run_end + 1]]
        if is_neutral_or_isolate(next_bc) {
          run_end += 1
        } else {
          break
        }
      }

      // Get preceding strong type
      let preceding = get_preceding_strong_type(
        types,
        indices,
        run_start,
        seq.sos,
      )

      // Get following strong type
      let following = get_following_strong_type(
        types,
        indices,
        run_end,
        seq.eos,
      )

      // N1: If preceding and following are same type, neutrals become that type
      // N2: Otherwise, neutrals become embedding direction
      let resolved : @bidi_data.BidiClass = if preceding == following {
        preceding
      } else if seq.level % 2 == 0 {
        @bidi_data.BidiClass::L
      } else {
        @bidi_data.BidiClass::R
      }

      // Apply resolved type to all neutrals in the run
      for j = run_start; j <= run_end; j = j + 1 {
        types[indices[j]] = resolved
      }
      i = run_end + 1
    } else {
      i += 1
    }
  }
}

///|
/// Check if type is neutral or isolate (for N rules)
fn is_neutral_or_isolate(bc : @bidi_data.BidiClass) -> Bool {
  match bc {
    B | S | WS | ON | LRI | RLI | FSI | PDI => true
    _ => false
  }
}

///|
/// Get the preceding strong type in the sequence
/// Returns effective strong type (L, R) - EN and AN become R
fn get_preceding_strong_type(
  types : Array[@bidi_data.BidiClass],
  indices : Array[Int],
  before_pos : Int,
  sos : @bidi_data.BidiClass,
) -> @bidi_data.BidiClass {
  let mut i = before_pos - 1
  while i >= 0 {
    let bc = types[indices[i]]
    match bc {
      L => return @bidi_data.BidiClass::L
      R => return @bidi_data.BidiClass::R
      EN | AN => return @bidi_data.BidiClass::R // EN and AN are treated as R
      _ => i -= 1
    }
  }
  sos
}

///|
/// Get the following strong type in the sequence
/// Returns effective strong type (L, R) - EN and AN become R
fn get_following_strong_type(
  types : Array[@bidi_data.BidiClass],
  indices : Array[Int],
  after_pos : Int,
  eos : @bidi_data.BidiClass,
) -> @bidi_data.BidiClass {
  let mut i = after_pos + 1
  while i < indices.length() {
    let bc = types[indices[i]]
    match bc {
      L => return @bidi_data.BidiClass::L
      R => return @bidi_data.BidiClass::R
      EN | AN => return @bidi_data.BidiClass::R // EN and AN are treated as R
      _ => i += 1
    }
  }
  eos
}
