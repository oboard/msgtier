///|
/// W1-W7: Weak Type Resolution
///
/// These rules resolve weak types (EN, ES, ET, AN, CS, NSM, BN)
/// within an isolating run sequence.

///|
/// Resolve weak types within an isolating run sequence
fn resolve_weak_types(
  types : Array[@bidi_data.BidiClass],
  _levels : Array[Int],
  seq : IsolatingRunSequence,
) -> Unit {
  let indices = seq.indices
  if indices.length() == 0 {
    return
  }

  // W1: NSM - Non-Spacing Mark
  // Examine each character that is not an isolate initiator or PDI.
  // If the previous character is an isolate initiator or PDI, change NSM to ON.
  // Otherwise, change NSM to the type of the previous character (or sos).
  let mut prev_type = seq.sos
  for idx in indices {
    let bc = types[idx]
    if bc == @bidi_data.BidiClass::NSM {
      // Check if previous character was isolate initiator or PDI
      // In resolved types, isolate initiators keep their type
      if prev_type.is_isolate_initiator() ||
        prev_type == @bidi_data.BidiClass::PDI {
        types[idx] = @bidi_data.BidiClass::ON
      } else {
        types[idx] = prev_type
      }
    }
    // Update prev_type (don't follow BN)
    if types[idx] != @bidi_data.BidiClass::BN {
      prev_type = types[idx]
    }
  }

  // W2: EN - European Number after AL
  // Search backward from each EN to find first strong type.
  // If it's AL, change EN to AN.
  for i = 0; i < indices.length(); i = i + 1 {
    let idx = indices[i]
    if types[idx] == @bidi_data.BidiClass::EN {
      // Search backward for strong type
      let mut j = i - 1
      while j >= 0 {
        let bc = types[indices[j]]
        match bc {
          AL => {
            types[idx] = @bidi_data.BidiClass::AN
            break
          }
          L | R => break
          _ => j -= 1
        }
      }
      // Also check sos
      if j < 0 && seq.sos == @bidi_data.BidiClass::AL {
        types[idx] = @bidi_data.BidiClass::AN
      }
    }
  }

  // W3: AL - Arabic Letter becomes R
  for idx in indices {
    if types[idx] == @bidi_data.BidiClass::AL {
      types[idx] = @bidi_data.BidiClass::R
    }
  }

  // W4: ES/CS between EN/AN
  // A single ES between two ENs becomes EN.
  // A single CS between two ENs becomes EN.
  // A single CS between two ANs becomes AN.
  for i = 1; i < indices.length() - 1; i = i + 1 {
    let idx = indices[i]
    let bc = types[idx]
    if bc == @bidi_data.BidiClass::ES || bc == @bidi_data.BidiClass::CS {
      let prev_idx = indices[i - 1]
      let next_idx = indices[i + 1]
      let prev_bc = types[prev_idx]
      let next_bc = types[next_idx]
      if bc == @bidi_data.BidiClass::ES &&
        prev_bc == @bidi_data.BidiClass::EN &&
        next_bc == @bidi_data.BidiClass::EN {
        types[idx] = @bidi_data.BidiClass::EN
      } else if bc == @bidi_data.BidiClass::CS {
        if prev_bc == @bidi_data.BidiClass::EN &&
          next_bc == @bidi_data.BidiClass::EN {
          types[idx] = @bidi_data.BidiClass::EN
        } else if prev_bc == @bidi_data.BidiClass::AN &&
          next_bc == @bidi_data.BidiClass::AN {
          types[idx] = @bidi_data.BidiClass::AN
        }
      }
    }
  }

  // W5: ET adjacent to EN becomes EN
  // A sequence of ETs adjacent to EN becomes EN.
  // First, find all ENs and expand to adjacent ETs
  for i = 0; i < indices.length(); i = i + 1 {
    let idx = indices[i]
    if types[idx] == @bidi_data.BidiClass::EN {
      // Look backward for ETs
      let mut j = i - 1
      while j >= 0 && types[indices[j]] == @bidi_data.BidiClass::ET {
        types[indices[j]] = @bidi_data.BidiClass::EN
        j -= 1
      }
      // Look forward for ETs
      j = i + 1
      while j < indices.length() &&
            types[indices[j]] == @bidi_data.BidiClass::ET {
        types[indices[j]] = @bidi_data.BidiClass::EN
        j += 1
      }
    }
  }

  // W6: ES, ET, CS become ON
  // All remaining ES, ET, and CS characters become ON.
  for idx in indices {
    let bc = types[idx]
    if bc == @bidi_data.BidiClass::ES ||
      bc == @bidi_data.BidiClass::ET ||
      bc == @bidi_data.BidiClass::CS {
      types[idx] = @bidi_data.BidiClass::ON
    }
  }

  // W7: EN becomes L when sos is L or after L
  // Search backward from each EN for first strong type.
  // If it's L, or if sos is L and no strong type found, change EN to L.
  for i = 0; i < indices.length(); i = i + 1 {
    let idx = indices[i]
    if types[idx] == @bidi_data.BidiClass::EN {
      // Search backward for strong type
      let mut found_strong = false
      let mut j = i - 1
      while j >= 0 {
        let bc = types[indices[j]]
        match bc {
          L => {
            types[idx] = @bidi_data.BidiClass::L
            found_strong = true
            break
          }
          R => {
            found_strong = true
            break
          }
          _ => j -= 1
        }
      }
      // Check sos
      if !found_strong && seq.sos == @bidi_data.BidiClass::L {
        types[idx] = @bidi_data.BidiClass::L
      }
    }
  }
}

///|
/// Re-resolve NSM after bracket pairing so combining marks follow
/// brackets that were retyped by N0.
fn resolve_nsm_after_brackets(
  types : Array[@bidi_data.BidiClass],
  original_classes : Array[@bidi_data.BidiClass],
  seq : IsolatingRunSequence,
) -> Unit {
  let indices = seq.indices
  if indices.length() == 0 {
    return
  }

  let mut prev_type = seq.sos
  for idx in indices {
    if original_classes[idx] == @bidi_data.BidiClass::NSM &&
      types[idx] == @bidi_data.BidiClass::ON {
      if prev_type.is_isolate_initiator() ||
        prev_type == @bidi_data.BidiClass::PDI {
        types[idx] = @bidi_data.BidiClass::ON
      } else {
        types[idx] = prev_type
      }
    }

    if types[idx] != @bidi_data.BidiClass::BN {
      prev_type = types[idx]
    }
  }
}
