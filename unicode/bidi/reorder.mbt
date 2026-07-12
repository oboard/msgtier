///|
/// L1-L4: Reordering Rules
///
/// These rules reorder characters for display based on resolved levels.

///|
/// L1: Reset levels of segment/paragraph separators and whitespace
fn reset_whitespace_levels(
  original_classes : Array[@bidi_data.BidiClass],
  levels : Array[Int],
  paragraph_level : Int,
) -> Unit {
  let len = levels.length()

  // L1: Reset levels for:
  // - Segment separators (S)
  // - Paragraph separators (B)
  // - Any whitespace (WS) or isolate formatting characters preceding S or B
  // - Any whitespace or isolate formatting at the end of the line

  // First, handle trailing whitespace
  // Note: X9-removed characters (LRE, RLE, LRO, RLO, PDF, BN) should be skipped
  // when detecting trailing whitespace, as they are conceptually removed by X9
  let mut i = len - 1
  while i >= 0 {
    let bc = original_classes[i]
    match bc {
      S | B => {
        levels[i] = paragraph_level
        // Reset preceding whitespace and isolates (skipping X9-removed chars)
        let mut j = i - 1
        while j >= 0 {
          let prev_bc = original_classes[j]
          match prev_bc {
            WS | LRI | RLI | FSI | PDI => {
              levels[j] = paragraph_level
              j -= 1
            }
            // Skip X9-removed characters
            LRE | RLE | LRO | RLO | PDF | BN => j -= 1
            _ => break
          }
        }
        i = j
      }
      WS | LRI | RLI | FSI | PDI => {
        // Trailing whitespace at end of paragraph
        levels[i] = paragraph_level
        i -= 1
      }
      // Skip X9-removed characters when detecting trailing whitespace
      LRE | RLE | LRO | RLO | PDF | BN => i -= 1
      _ => break
    }
  }

  // Also reset any S or B in the middle, plus preceding whitespace/isolates
  for k = 0; k < len; k = k + 1 {
    let bc = original_classes[k]
    if bc == @bidi_data.BidiClass::S || bc == @bidi_data.BidiClass::B {
      levels[k] = paragraph_level
      // L1.3: Reset preceding whitespace and isolate formatting characters
      // (skipping X9-removed characters)
      let mut j = k - 1
      while j >= 0 {
        let prev_bc = original_classes[j]
        match prev_bc {
          WS | LRI | RLI | FSI | PDI => {
            levels[j] = paragraph_level
            j -= 1
          }
          // Skip X9-removed characters
          LRE | RLE | LRO | RLO | PDF | BN => j -= 1
          _ => break
        }
      }
    }
  }
}

///|
/// L2: Reorder text based on levels
/// Returns indices in visual order
fn apply_reordering(
  indices : Array[Int],
  levels : Array[Int],
  paragraph_level : Int,
) -> Array[Int] {
  let len = indices.length()
  if len == 0 {
    return []
  }

  // Initialize result with logical order after X9 removal.
  let result = indices.copy()

  // Find the maximum level in the remaining indices.
  let mut max_level = paragraph_level
  for idx in result {
    let level = levels[idx]
    if level > max_level {
      max_level = level
    }
  }

  // L2: From the highest level to the lowest odd level, reverse each
  // contiguous sequence of characters at that level or higher.
  let mut level = max_level
  while level >= 1 {
    let mut i = 0
    while i < len {
      if levels[result[i]] >= level {
        let start = i
        while i < len && levels[result[i]] >= level {
          i += 1
        }
        reverse_range(result, start, i - 1)
      } else {
        i += 1
      }
    }
    level -= 1
  }
  result
}

///|
/// Reverse a range in an array
fn reverse_range(arr : Array[Int], start : Int, end : Int) -> Unit {
  let mut lo = start
  let mut hi = end
  while lo < hi {
    let tmp = arr[lo]
    arr[lo] = arr[hi]
    arr[hi] = tmp
    lo += 1
    hi -= 1
  }
}
