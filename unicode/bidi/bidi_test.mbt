///|
/// Unit tests for the Unicode Bidirectional Algorithm

///|
test "detect_direction: pure LTR text" {
  inspect(@bidi.detect_direction("Hello World"), content="LTR")
}

///|
test "detect_direction: pure RTL text (Hebrew)" {
  // Hebrew: Shalom
  inspect(
    @bidi.detect_direction("\u{05E9}\u{05DC}\u{05D5}\u{05DD}"),
    content="RTL",
  )
}

///|
test "detect_direction: pure RTL text (Arabic)" {
  // Arabic: Marhaba (Hello)
  inspect(
    @bidi.detect_direction("\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}"),
    content="RTL",
  )
}

///|
test "detect_direction: mixed starts with LTR" {
  inspect(
    @bidi.detect_direction("Hello \u{05E9}\u{05DC}\u{05D5}\u{05DD}"),
    content="LTR",
  )
}

///|
test "detect_direction: mixed starts with RTL" {
  inspect(
    @bidi.detect_direction("\u{05E9}\u{05DC}\u{05D5}\u{05DD} Hello"),
    content="RTL",
  )
}

///|
test "detect_direction: empty string" {
  inspect(@bidi.detect_direction(""), content="LTR")
}

///|
test "detect_direction: numbers only" {
  // Numbers are weak types, should default to LTR
  inspect(@bidi.detect_direction("12345"), content="LTR")
}

///|
test "requires_bidi: pure LTR" {
  inspect(@bidi.requires_bidi("Hello World"), content="false")
}

///|
test "requires_bidi: contains RTL" {
  inspect(
    @bidi.requires_bidi("Hello \u{05E9}\u{05DC}\u{05D5}\u{05DD}"),
    content="true",
  )
}

///|
test "requires_bidi: contains Arabic" {
  inspect(@bidi.requires_bidi("\u{0627}\u{0644}\u{0639}"), content="true")
}

///|
test "process: pure LTR text" {
  let result = @bidi.process("abc")
  inspect(result.base_level, content="0")
  @debug.debug_inspect(result.levels, content="[0, 0, 0]")
}

///|
test "process: pure RTL text (Hebrew)" {
  // Hebrew letters: alef, bet, gimel
  let result = @bidi.process("\u{05D0}\u{05D1}\u{05D2}")
  inspect(result.base_level, content="1")
  // All RTL characters should be at level 1
  @debug.debug_inspect(result.levels, content="[1, 1, 1]")
}

///|
test "process: mixed LTR and RTL" {
  // "ABC" followed by Hebrew alef, bet, gimel
  let result = @bidi.process("ABC\u{05D0}\u{05D1}\u{05D2}")
  inspect(result.base_level, content="0")
  // LTR at level 0, RTL at level 1
  @debug.debug_inspect(result.levels, content="[0, 0, 0, 1, 1, 1]")
}

///|
test "reorder: pure LTR" {
  let result = @bidi.process("abc")
  let order = @bidi.reorder(result)
  // LTR text should remain in logical order
  @debug.debug_inspect(order, content="[0, 1, 2]")
}

///|
test "reorder: pure RTL" {
  // Hebrew letters
  let result = @bidi.process("\u{05D0}\u{05D1}\u{05D2}")
  let order = @bidi.reorder(result)
  // RTL text should be reversed
  @debug.debug_inspect(order, content="[2, 1, 0]")
}

///|
test "reorder: mixed text" {
  // "ab" followed by Hebrew alef, bet
  let result = @bidi.process("ab\u{05D0}\u{05D1}")
  let order = @bidi.reorder(result)
  // LTR stays, RTL reversed
  @debug.debug_inspect(order, content="[0, 1, 3, 2]")
}

///|
test "reorder_string: pure LTR" {
  let result = @bidi.process("abc")
  inspect(@bidi.reorder_string(result), content="abc")
}

///|
test "reorder_string: pure RTL" {
  // Hebrew alef, bet, gimel -> gimel, bet, alef visually
  let result = @bidi.process("\u{05D0}\u{05D1}\u{05D2}")
  inspect(@bidi.reorder_string(result), content="\u{05D2}\u{05D1}\u{05D0}")
}

///|
test "bidi_class: ASCII letters" {
  inspect(@bidi.bidi_class('A'), content="L")
  inspect(@bidi.bidi_class('z'), content="L")
}

///|
test "bidi_class: Hebrew letters" {
  inspect(@bidi.bidi_class('\u{05D0}'), content="R") // Alef
  inspect(@bidi.bidi_class('\u{05EA}'), content="R") // Tav
}

///|
test "bidi_class: Arabic letters" {
  inspect(@bidi.bidi_class('\u{0627}'), content="AL") // Alif
  inspect(@bidi.bidi_class('\u{0628}'), content="AL") // Ba
}

///|
test "bidi_class: European numbers" {
  inspect(@bidi.bidi_class('0'), content="EN")
  inspect(@bidi.bidi_class('9'), content="EN")
}

///|
test "bidi_class: Arabic-Indic digits" {
  inspect(@bidi.bidi_class('\u{0660}'), content="AN") // Arabic-Indic 0
  inspect(@bidi.bidi_class('\u{0669}'), content="AN") // Arabic-Indic 9
}

///|
test "bidi_class: common separators" {
  inspect(@bidi.bidi_class(','), content="CS")
  inspect(@bidi.bidi_class('.'), content="CS")
}

///|
test "bidi_class: whitespace" {
  inspect(@bidi.bidi_class(' '), content="WS")
}

///|
test "get_mirrored: parentheses at RTL level" {
  inspect(@bidi.get_mirrored('(', 1), content=")")
  inspect(@bidi.get_mirrored(')', 1), content="(")
}

///|
test "get_mirrored: parentheses at LTR level" {
  inspect(@bidi.get_mirrored('(', 0), content="(")
  inspect(@bidi.get_mirrored(')', 0), content=")")
}

///|
test "get_mirrored: angle brackets" {
  inspect(@bidi.get_mirrored('<', 1), content=">")
  inspect(@bidi.get_mirrored('>', 1), content="<")
}

///|
test "Direction::level" {
  inspect(@bidi.Direction::LTR.level(), content="0")
  inspect(@bidi.Direction::RTL.level(), content="1")
}

///|
test "direction_from_level: even levels" {
  inspect(@bidi.direction_from_level(0), content="LTR")
  inspect(@bidi.direction_from_level(2), content="LTR")
  inspect(@bidi.direction_from_level(4), content="LTR")
}

///|
test "direction_from_level: odd levels" {
  inspect(@bidi.direction_from_level(1), content="RTL")
  inspect(@bidi.direction_from_level(3), content="RTL")
  inspect(@bidi.direction_from_level(5), content="RTL")
}

///|
test "process: numbers in LTR context" {
  let result = @bidi.process("abc123def")
  // All should be at level 0 (EN promoted to L at LTR level)
  @debug.debug_inspect(result.levels, content="[0, 0, 0, 0, 0, 0, 0, 0, 0]")
}

///|
test "process: numbers in RTL context" {
  // Hebrew text with numbers
  let result = @bidi.process("\u{05D0}123\u{05D1}")
  inspect(result.base_level, content="1")
  // Hebrew at level 1, numbers at level 2 (EN in RTL context)
  @debug.debug_inspect(result.levels, content="[1, 2, 2, 2, 1]")
}

///|
test "process_with_direction: force LTR" {
  // Hebrew text forced to LTR direction
  let result = @bidi.process_with_direction(
    "\u{05D0}\u{05D1}\u{05D2}",
    @bidi.Direction::LTR,
  )
  inspect(result.base_level, content="0")
}

///|
test "process_with_direction: force RTL" {
  // English text forced to RTL direction
  let result = @bidi.process_with_direction("ABC", @bidi.Direction::RTL)
  inspect(result.base_level, content="1")
}
