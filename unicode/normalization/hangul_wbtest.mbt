///|
test "hangul syllable detection" {
  // 가 (U+AC00) is the first Hangul syllable
  assert_true(is_hangul_syllable('\u{AC00}'))
  // 힣 (U+D7A3) is the last Hangul syllable
  assert_true(is_hangul_syllable('\u{D7A3}'))
  // ASCII is not a Hangul syllable
  assert_false(is_hangul_syllable('A'))
  // Just before Hangul block
  assert_false(is_hangul_syllable('\u{ABFF}'))
  // Just after Hangul block
  assert_false(is_hangul_syllable('\u{D7A4}'))
}

///|
test "hangul jamo detection" {
  // Leading consonant jamo (L)
  assert_true(is_hangul_l('\u{1100}')) // ᄀ
  assert_true(is_hangul_l('\u{1112}')) // ᄒ (last L)
  assert_false(is_hangul_l('\u{1113}')) // Beyond L range
  // Vowel jamo (V)
  assert_true(is_hangul_v('\u{1161}')) // ᅡ
  assert_true(is_hangul_v('\u{1175}')) // ᅵ (last V)
  assert_false(is_hangul_v('\u{1176}')) // Beyond V range
  // Trailing consonant jamo (T)
  assert_false(is_hangul_t('\u{11A7}')) // T_BASE itself is not valid
  assert_true(is_hangul_t('\u{11A8}')) // ᆨ (first T)
  assert_true(is_hangul_t('\u{11C2}')) // ᇂ (last T)
}

///|
test "hangul LV syllable detection" {
  // 가 (U+AC00) is LV (no trailing)
  assert_true(is_hangul_lv('\u{AC00}'))
  // 각 (U+AC01) is LVT (has trailing ᆨ)
  assert_false(is_hangul_lv('\u{AC01}'))
  // 나 (U+B098) is LV
  assert_true(is_hangul_lv('\u{B098}'))
}

///|
test "hangul decomposition LV" {
  // 가 (U+AC00) = ᄀ (U+1100) + ᅡ (U+1161)
  let result = decompose_hangul('\u{AC00}')
  @debug.debug_inspect(result, content="['ᄀ', 'ᅡ']")
}

///|
test "hangul decomposition LVT" {
  // 각 (U+AC01) = ᄀ (U+1100) + ᅡ (U+1161) + ᆨ (U+11A8)
  let result = decompose_hangul('\u{AC01}')
  @debug.debug_inspect(result, content="['ᄀ', 'ᅡ', 'ᆨ']")
}

///|
test "hangul decomposition various" {
  // 한 (U+D55C) = ᄒ (U+1112) + ᅡ (U+1161) + ᆫ (U+11AB)
  let result = decompose_hangul('\u{D55C}')
  @debug.debug_inspect(result, content="['ᄒ', 'ᅡ', 'ᆫ']")
}

///|
test "hangul composition L+V" {
  // ᄀ + ᅡ -> 가
  let result = try_compose_hangul('\u{1100}', '\u{1161}')
  @debug.debug_inspect(result, content="Some('가')")
}

///|
test "hangul composition LV+T" {
  // 가 + ᆨ -> 각
  let result = try_compose_hangul('\u{AC00}', '\u{11A8}')
  @debug.debug_inspect(result, content="Some('각')")
}

///|
test "hangul composition invalid" {
  // L + T should not compose
  let result = try_compose_hangul('\u{1100}', '\u{11A8}')
  @debug.debug_inspect(result, content="None")
  // V + V should not compose
  let result2 = try_compose_hangul('\u{1161}', '\u{1162}')
  @debug.debug_inspect(result2, content="None")
  // ASCII should not compose
  let result3 = try_compose_hangul('A', 'B')
  @debug.debug_inspect(result3, content="None")
}

///|
test "hangul roundtrip" {
  // Decompose and recompose should give same result
  let original = '\u{AC01}' // 각
  let decomposed = decompose_hangul(original)
  // Compose L + V first
  let lv = try_compose_hangul(decomposed[0], decomposed[1])
  guard lv is Some(lv_val) else { fail("L+V should compose") }
  // Then compose LV + T
  let lvt = try_compose_hangul(lv_val, decomposed[2])
  @debug.debug_inspect(lvt, content="Some('각')")
}
