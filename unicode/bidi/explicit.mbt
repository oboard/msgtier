///|
/// X1-X10: Explicit Formatting Character Processing
///
/// This handles embeddings (LRE, RLE, LRO, RLO, PDF) and
/// isolates (LRI, RLI, FSI, PDI).

///|
/// Directional status stack entry
priv struct DirectionalStatus {
  level : Int
  override_status : @bidi_data.BidiClass // L, R, or ON (neutral = no override)
  isolate_status : Bool
}

///|
/// Process explicit formatting characters (X1-X10)
/// Returns list of (isolate_initiator_index, pdi_index) pairs
fn process_explicit(
  types : Array[@bidi_data.BidiClass],
  levels : Array[Int],
  paragraph_level : Int,
) -> Array[(Int, Int)] {
  // X1: Initialize directional status stack
  let stack : Array[DirectionalStatus] = [
    {
      level: paragraph_level,
      override_status: @bidi_data.BidiClass::ON,
      isolate_status: false,
    },
  ]
  let overflow_isolate_count : Ref[Int] = { val: 0 }
  let overflow_embedding_count : Ref[Int] = { val: 0 }
  let valid_isolate_count : Ref[Int] = { val: 0 }

  // Track isolate pairs for later run sequence computation
  let isolate_pairs : Array[(Int, Int)] = []
  let isolate_stack : Array[Int] = [] // Stack of isolate initiator indices
  for i = 0; i < types.length(); i = i + 1 {
    let bc = types[i]
    match bc {
      // X2: RLE - Right-to-Left Embedding
      RLE => {
        let new_level = next_odd_level(stack[stack.length() - 1].level)
        if new_level <= max_depth &&
          overflow_isolate_count.val == 0 &&
          overflow_embedding_count.val == 0 {
          stack.push({
            level: new_level,
            override_status: @bidi_data.BidiClass::ON,
            isolate_status: false,
          })
        } else if overflow_isolate_count.val == 0 {
          overflow_embedding_count.val += 1
        }
        // X9: Remove from output (set level, keep type for X9 removal)
        levels[i] = stack[stack.length() - 1].level
        types[i] = @bidi_data.BidiClass::BN
      }

      // X3: LRE - Left-to-Right Embedding
      LRE => {
        let new_level = next_even_level(stack[stack.length() - 1].level)
        if new_level <= max_depth &&
          overflow_isolate_count.val == 0 &&
          overflow_embedding_count.val == 0 {
          stack.push({
            level: new_level,
            override_status: @bidi_data.BidiClass::ON,
            isolate_status: false,
          })
        } else if overflow_isolate_count.val == 0 {
          overflow_embedding_count.val += 1
        }
        levels[i] = stack[stack.length() - 1].level
        types[i] = @bidi_data.BidiClass::BN
      }

      // X4: RLO - Right-to-Left Override
      RLO => {
        let new_level = next_odd_level(stack[stack.length() - 1].level)
        if new_level <= max_depth &&
          overflow_isolate_count.val == 0 &&
          overflow_embedding_count.val == 0 {
          stack.push({
            level: new_level,
            override_status: @bidi_data.BidiClass::R,
            isolate_status: false,
          })
        } else if overflow_isolate_count.val == 0 {
          overflow_embedding_count.val += 1
        }
        levels[i] = stack[stack.length() - 1].level
        types[i] = @bidi_data.BidiClass::BN
      }

      // X5: LRO - Left-to-Right Override
      LRO => {
        let new_level = next_even_level(stack[stack.length() - 1].level)
        if new_level <= max_depth &&
          overflow_isolate_count.val == 0 &&
          overflow_embedding_count.val == 0 {
          stack.push({
            level: new_level,
            override_status: @bidi_data.BidiClass::L,
            isolate_status: false,
          })
        } else if overflow_isolate_count.val == 0 {
          overflow_embedding_count.val += 1
        }
        levels[i] = stack[stack.length() - 1].level
        types[i] = @bidi_data.BidiClass::BN
      }

      // X5a: RLI - Right-to-Left Isolate
      RLI => {
        levels[i] = stack[stack.length() - 1].level
        let ovr = stack[stack.length() - 1].override_status
        if ovr != @bidi_data.BidiClass::ON {
          types[i] = ovr
        }
        let new_level = next_odd_level(stack[stack.length() - 1].level)
        if new_level <= max_depth &&
          overflow_isolate_count.val == 0 &&
          overflow_embedding_count.val == 0 {
          valid_isolate_count.val += 1
          isolate_stack.push(i)
          stack.push({
            level: new_level,
            override_status: @bidi_data.BidiClass::ON,
            isolate_status: true,
          })
        } else {
          overflow_isolate_count.val += 1
        }
      }

      // X5b: LRI - Left-to-Right Isolate
      LRI => {
        levels[i] = stack[stack.length() - 1].level
        let ovr = stack[stack.length() - 1].override_status
        if ovr != @bidi_data.BidiClass::ON {
          types[i] = ovr
        }
        let new_level = next_even_level(stack[stack.length() - 1].level)
        if new_level <= max_depth &&
          overflow_isolate_count.val == 0 &&
          overflow_embedding_count.val == 0 {
          valid_isolate_count.val += 1
          isolate_stack.push(i)
          stack.push({
            level: new_level,
            override_status: @bidi_data.BidiClass::ON,
            isolate_status: true,
          })
        } else {
          overflow_isolate_count.val += 1
        }
      }

      // X5c: FSI - First Strong Isolate
      FSI => {
        levels[i] = stack[stack.length() - 1].level
        let ovr = stack[stack.length() - 1].override_status
        if ovr != @bidi_data.BidiClass::ON {
          types[i] = ovr
        }
        // Determine direction of isolate content
        let isolate_dir = determine_isolate_direction(types, i + 1)
        let new_level = if isolate_dir == RTL {
          next_odd_level(stack[stack.length() - 1].level)
        } else {
          next_even_level(stack[stack.length() - 1].level)
        }
        if new_level <= max_depth &&
          overflow_isolate_count.val == 0 &&
          overflow_embedding_count.val == 0 {
          valid_isolate_count.val += 1
          isolate_stack.push(i)
          stack.push({
            level: new_level,
            override_status: @bidi_data.BidiClass::ON,
            isolate_status: true,
          })
        } else {
          overflow_isolate_count.val += 1
        }
      }

      // X6a: PDI - Pop Directional Isolate
      PDI => {
        if overflow_isolate_count.val > 0 {
          overflow_isolate_count.val -= 1
        } else if valid_isolate_count.val > 0 {
          overflow_embedding_count.val = 0
          // Pop until isolate
          while stack.length() > 1 && !stack[stack.length() - 1].isolate_status {
            let _ = stack.pop()
          }
          // Pop the isolate entry itself
          if stack.length() > 1 {
            let _ = stack.pop()
          }
          valid_isolate_count.val -= 1
          // Record isolate pair
          if isolate_stack.length() > 0 {
            match isolate_stack.pop() {
              Some(start) => isolate_pairs.push((start, i))
              None => ()
            }
          }
        }
        levels[i] = stack[stack.length() - 1].level
        let ovr = stack[stack.length() - 1].override_status
        if ovr != @bidi_data.BidiClass::ON {
          types[i] = ovr
        }
      }

      // X7: PDF - Pop Directional Formatting
      PDF => {
        if overflow_isolate_count.val > 0 {
          // Do nothing
        } else if overflow_embedding_count.val > 0 {
          overflow_embedding_count.val -= 1
        } else if stack.length() >= 2 &&
          !stack[stack.length() - 1].isolate_status {
          let _ = stack.pop()
        }
        levels[i] = stack[stack.length() - 1].level
        types[i] = @bidi_data.BidiClass::BN
      }

      // X6: For all other types
      _ => {
        levels[i] = stack[stack.length() - 1].level
        let ovr = stack[stack.length() - 1].override_status
        if ovr != @bidi_data.BidiClass::ON && bc != @bidi_data.BidiClass::BN {
          types[i] = ovr
        }
      }
    }
  }
  isolate_pairs
}

///|
/// Ensure NSM levels follow the last non-X9 character.
fn adjust_nsm_levels(
  original_classes : Array[@bidi_data.BidiClass],
  levels : Array[Int],
) -> Unit {
  let mut last_idx = -1
  let mut saw_explicit = false
  for i = 0; i < original_classes.length(); i = i + 1 {
    let bc = original_classes[i]
    if bc == @bidi_data.BidiClass::LRE ||
      bc == @bidi_data.BidiClass::LRO ||
      bc == @bidi_data.BidiClass::RLE ||
      bc == @bidi_data.BidiClass::RLO ||
      bc == @bidi_data.BidiClass::PDF ||
      bc.is_isolate_initiator() {
      saw_explicit = true
    }
    if bc == @bidi_data.BidiClass::NSM && last_idx >= 0 {
      let last_bc = original_classes[last_idx]
      if !last_bc.is_isolate_initiator() &&
        last_bc != @bidi_data.BidiClass::PDI &&
        !saw_explicit {
        levels[i] = levels[last_idx]
      }
    }
    if !bc.is_x9_removed() {
      last_idx = i
      saw_explicit = false
    }
  }
}

///|
/// Determine direction for FSI by finding first strong character
fn determine_isolate_direction(
  types : Array[@bidi_data.BidiClass],
  start : Int,
) -> Direction {
  let mut isolate_count = 0
  for i = start; i < types.length(); i = i + 1 {
    let bc = types[i]
    if bc.is_isolate_initiator() {
      isolate_count += 1
    } else if bc == @bidi_data.BidiClass::PDI {
      if isolate_count > 0 {
        isolate_count -= 1
      } else {
        // End of our isolate content
        break
      }
    } else if isolate_count == 0 {
      match bc {
        R | AL => return RTL
        L => return LTR
        _ => ()
      }
    }
  }
  LTR // Default
}

///|
/// Get next odd level >= current
fn next_odd_level(level : Int) -> Int {
  (level + 1) | 1
}

///|
/// Get next even level >= current
fn next_even_level(level : Int) -> Int {
  (level + 2) & (1).lnot()
}

///|
/// Isolating run sequence - indices of characters that form a sequence
priv struct IsolatingRunSequence {
  indices : Array[Int] // Character indices in this sequence
  sos : @bidi_data.BidiClass // Start-of-sequence type (L or R)
  eos : @bidi_data.BidiClass // End-of-sequence type (L or R)
  level : Int // Embedding level of the sequence
}

///|
/// Compute isolating run sequences (X10)
fn compute_isolating_run_sequences(
  types : Array[@bidi_data.BidiClass],
  levels : Array[Int],
  original_classes : Array[@bidi_data.BidiClass],
  paragraph_level : Int,
  isolate_pairs : Array[(Int, Int)],
) -> Array[IsolatingRunSequence] {
  let len = types.length()
  if len == 0 {
    return []
  }

  // Build a map from isolate initiator to PDI
  let isolate_to_pdi : Map[Int, Int] = Map([])
  for pair in isolate_pairs {
    isolate_to_pdi[pair.0] = pair.1
  }
  let sequences : Array[IsolatingRunSequence] = []
  let processed : Array[Bool] = Array::make(len, false)

  // Find level runs and connect them via isolate pairs
  for i = 0; i < len; i = i + 1 {
    if processed[i] {
      continue
    }

    // Skip BN and explicit formatting characters
    let bc = types[i]
    if bc == @bidi_data.BidiClass::BN {
      processed[i] = true
      continue
    }

    // Start a new isolating run sequence
    let indices : Array[Int] = []
    let seq_level = levels[i]
    let mut current = i

    // Follow the run, linking through isolate pairs
    while current < len {
      // Add all characters at the same level in this run
      while current < len {
        if processed[current] {
          current += 1
          continue
        }
        if types[current] == @bidi_data.BidiClass::BN {
          processed[current] = true
          current += 1
          continue
        }
        if levels[current] != seq_level {
          break
        }
        indices.push(current)
        processed[current] = true
        current += 1
      }

      // Check if last added character is an isolate initiator
      if indices.length() > 0 {
        let last = indices[indices.length() - 1]
        match isolate_to_pdi.get(last) {
          Some(pdi_idx) =>
            // Continue sequence at the matching PDI run (include the PDI).
            current = pdi_idx
          None => break
        }
      } else {
        break
      }
    }
    if indices.length() == 0 {
      continue
    }

    // Compute sos and eos
    let first_idx = indices[0]
    let last_idx = indices[indices.length() - 1]

    // sos: higher of level before sequence and sequence level
    let level_before = if first_idx == 0 {
      paragraph_level
    } else {
      // Find previous character level (skip BN)
      let mut prev = first_idx - 1
      while prev > 0 && types[prev] == @bidi_data.BidiClass::BN {
        prev -= 1
      }
      if prev < 0 || types[prev] == @bidi_data.BidiClass::BN {
        paragraph_level
      } else if original_classes[prev] == @bidi_data.BidiClass::B {
        paragraph_level
      } else {
        levels[prev]
      }
    }
    let sos_level = @cmp.maximum(level_before, seq_level)
    let sos : @bidi_data.BidiClass = if sos_level % 2 == 0 {
      @bidi_data.BidiClass::L
    } else {
      @bidi_data.BidiClass::R
    }

    // eos: higher of level after sequence and sequence level
    let level_after = if last_idx >= len - 1 {
      paragraph_level
    } else if original_classes[last_idx] == @bidi_data.BidiClass::B {
      paragraph_level
    } else {
      // Find next character level (skip BN)
      let mut next = last_idx + 1
      while next < len && types[next] == @bidi_data.BidiClass::BN {
        next += 1
      }
      // Check if this is an isolate initiator - look for matching PDI
      let last_type = types[last_idx]
      if last_type.is_isolate_initiator() {
        match isolate_to_pdi.get(last_idx) {
          Some(pdi_idx) => levels[pdi_idx]
          None => paragraph_level
        }
      } else if next >= len {
        paragraph_level
      } else if original_classes[next] == @bidi_data.BidiClass::B {
        paragraph_level
      } else {
        levels[next]
      }
    }
    let eos_level = @cmp.maximum(level_after, seq_level)
    let eos : @bidi_data.BidiClass = if eos_level % 2 == 0 {
      @bidi_data.BidiClass::L
    } else {
      @bidi_data.BidiClass::R
    }
    sequences.push({ indices, sos, eos, level: seq_level })
  }
  sequences
}
