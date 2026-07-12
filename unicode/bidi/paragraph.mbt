///|
/// P1-P3: Paragraph Level Determination
///
/// P1: Split the text into separate paragraphs.
/// P2: In each paragraph, find the first character of type L, AL, or R
///     while skipping over any characters between an isolate initiator
///     and its matching PDI or, if it has no matching PDI, the end of the
///     paragraph.
/// P3: If a character is found in P2 and it is of type AL or R, then set
///     the paragraph embedding level to one; otherwise, set it to zero.

///|
/// Determine the paragraph embedding level for text
/// P2-P3: Find first strong character not in isolate, return its level
fn determine_paragraph_level(text : String, default_level~ : Int) -> Int {
  let mut isolate_count = 0
  for c in text {
    let bc = @bidi_data.lookup_bidi_class(c)

    // Skip characters inside isolates
    if bc.is_isolate_initiator() {
      isolate_count += 1
      continue
    }
    if bc == PDI {
      if isolate_count > 0 {
        isolate_count -= 1
      }
      continue
    }

    // Only look at characters outside isolates
    if isolate_count == 0 {
      match bc {
        // P3: If AL or R, paragraph level is 1 (RTL)
        AL | R => return 1
        // P3: If L, paragraph level is 0 (LTR)
        L => return 0
        _ => ()
      }
    }
  }

  // P3: If no strong character found, use default
  default_level
}
