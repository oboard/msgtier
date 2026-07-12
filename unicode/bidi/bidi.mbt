///|
/// Unicode Bidirectional Algorithm (UAX #9)
///
/// This module implements the Unicode Bidirectional Algorithm for
/// determining the display order of text containing both left-to-right
/// and right-to-left characters.

///|
/// Error types for Bidi processing
pub(all) suberror BidiError {
  InvalidIsolate(String) // Mismatched isolate initiator/PDI
  StackOverflow // Embedding level stack overflow (max 125)
}

///|
/// Direction of text
pub(all) enum Direction {
  LTR // Left-to-Right (base level 0)
  RTL // Right-to-Left (base level 1)
} derive(Eq)

///|
pub impl Show for Direction with fn output(self, logger) {
  match self {
    LTR => logger.write_string("LTR")
    RTL => logger.write_string("RTL")
  }
}

///|
/// Result of bidi processing - a paragraph with resolved levels
pub(all) struct BidiParagraph {
  /// Original characters
  chars : Array[Char]
  /// Original Bidi classes (before resolution)
  original_classes : Array[@bidi_data.BidiClass]
  /// Resolved Bidi classes (after W and N rules)
  resolved_classes : Array[@bidi_data.BidiClass]
  /// Resolved embedding level per character (0-125)
  levels : Array[Int]
  /// Paragraph embedding level (0 for LTR, 1 for RTL)
  base_level : Int
}

///|
/// Maximum embedding level allowed by UAX #9
let max_depth : Int = 125

///|
pub using @bidi_data {type BidiClass}

///|
/// Look up Bidi_Class for a character
pub fn bidi_class(c : Char) -> BidiClass {
  @bidi_data.lookup_bidi_class(c)
}

///|
/// Detect the base direction of text (P2-P3)
/// Returns the direction of the first strong character,
/// or LTR if no strong character is found
pub fn detect_direction(text : String) -> Direction {
  let level = determine_paragraph_level(text, default_level=0)
  if level == 0 {
    LTR
  } else {
    RTL
  }
}

///|
/// Check if text requires bidi processing
/// Returns false for pure LTR text (optimization)
pub fn requires_bidi(text : String) -> Bool {
  for c in text {
    if @bidi_data.is_strong_rtl(c) || @bidi_data.is_explicit_formatting(c) {
      return true
    }
  }
  false
}

///|
/// Process text according to the Unicode Bidirectional Algorithm
/// Returns a BidiParagraph with resolved embedding levels for each character
pub fn process(text : String) -> BidiParagraph {
  let base_level = determine_paragraph_level(text, default_level=0)
  process_with_base_level(text, base_level)
}

///|
/// Process text with explicit base direction
/// Use when the paragraph direction is known externally
pub fn process_with_direction(
  text : String,
  direction : Direction,
) -> BidiParagraph {
  let base_level = match direction {
    LTR => 0
    RTL => 1
  }
  process_with_base_level(text, base_level)
}

///|
/// Process text with explicit base level
pub fn process_with_base_level(
  text : String,
  base_level : Int,
) -> BidiParagraph {
  // Convert to char array and get original classes
  let chars : Array[Char] = []
  for c in text {
    chars.push(c)
  }
  let original_classes : Array[@bidi_data.BidiClass] = chars.map(
    @bidi_data.lookup_bidi_class,
  )

  // Make a copy for resolution
  let resolved_classes = original_classes.copy()

  // Allocate levels array
  let levels : Array[Int] = Array::make(chars.length(), base_level)

  // X1-X10: Process explicit formatting characters
  let isolate_pairs = process_explicit(resolved_classes, levels, base_level)

  // Align NSM levels with the previous non-X9 character.
  adjust_nsm_levels(original_classes, levels)

  // Compute isolating run sequences and process each
  let sequences = compute_isolating_run_sequences(
    resolved_classes, levels, original_classes, base_level, isolate_pairs,
  )
  for seq in sequences {
    // W1-W7: Resolve weak types
    resolve_weak_types(resolved_classes, levels, seq)

    // N0: Resolve bracket pairs
    resolve_bracket_pairs(chars, resolved_classes, levels, seq)

    // Adjust NSM after bracket resolution (N0)
    resolve_nsm_after_brackets(resolved_classes, original_classes, seq)

    // N1-N2: Resolve neutral types
    resolve_neutral_types(resolved_classes, levels, seq)
  }

  // I1-I2: Apply implicit levels
  apply_implicit_levels(resolved_classes, levels)

  // L1: Reset whitespace and separator levels
  reset_whitespace_levels(original_classes, levels, base_level)
  { chars, original_classes, resolved_classes, levels, base_level }
}

///|
/// Reorder text for display according to resolved levels
/// Returns array of character indices in visual order
/// X9-removed characters (LRE, RLE, LRO, RLO, PDF, BN) are excluded
pub fn reorder(para : BidiParagraph) -> Array[Int] {
  // X9: remove explicit formatting and BN before reordering.
  let indices : Array[Int] = []
  for i = 0; i < para.levels.length(); i = i + 1 {
    let bc = para.original_classes[i]
    if !bc.is_x9_removed() {
      indices.push(i)
    }
  }
  apply_reordering(indices, para.levels, para.base_level)
}

///|
/// Reorder text and return the visually-ordered string
pub fn reorder_string(para : BidiParagraph) -> String {
  let order = reorder(para)
  let sb = StringBuilder::new()
  for i in order {
    let c = para.chars[i]
    let level = para.levels[i]
    // Apply mirroring for RTL levels (odd levels)
    if level % 2 == 1 {
      sb.write_char(@bidi_data.bidi_mirroring_glyph(c))
    } else {
      sb.write_char(c)
    }
  }
  sb.to_string()
}

///|
/// Get the mirrored glyph for a character if in RTL context
pub fn get_mirrored(c : Char, level : Int) -> Char {
  if level % 2 == 1 {
    @bidi_data.bidi_mirroring_glyph(c)
  } else {
    c
  }
}

///|
/// Get embedding level for direction
pub fn Direction::level(self : Direction) -> Int {
  match self {
    LTR => 0
    RTL => 1
  }
}

///|
/// Get direction from embedding level
pub fn direction_from_level(level : Int) -> Direction {
  if level % 2 == 0 {
    LTR
  } else {
    RTL
  }
}
