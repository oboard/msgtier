///|
/// Hangul syllable constants (from Unicode Chapter 3.12)
/// These enable algorithmic decomposition/composition without lookup tables

///|
/// First Hangul syllable (가)
let hangul_s_base : Int = 0xAC00

///|
/// First leading consonant jamo (ᄀ)
let hangul_l_base : Int = 0x1100

///|
/// First vowel jamo (ᅡ)
let hangul_v_base : Int = 0x1161

///|
/// First trailing consonant jamo (ᆨ) - note: T_BASE itself represents no trailing
let hangul_t_base : Int = 0x11A7

///|
/// Number of leading consonant jamo (19)
let hangul_l_count : Int = 19

///|
/// Number of vowel jamo (21)
let hangul_v_count : Int = 21

///|
/// Number of trailing consonant jamo including none (28)
let hangul_t_count : Int = 28

///|
/// V_COUNT * T_COUNT = 588
let hangul_n_count : Int = 588

///|
/// Total number of Hangul syllables (11172)
let hangul_s_count : Int = 11172

///|
/// Check if a character is a precomposed Hangul syllable
fn is_hangul_syllable(c : Char) -> Bool {
  let cp = c.to_int()
  cp >= hangul_s_base && cp < hangul_s_base + hangul_s_count
}

///|
/// Check if a character is a leading consonant jamo (L)
fn is_hangul_l(c : Char) -> Bool {
  let cp = c.to_int()
  cp >= hangul_l_base && cp < hangul_l_base + hangul_l_count
}

///|
/// Check if a character is a vowel jamo (V)
fn is_hangul_v(c : Char) -> Bool {
  let cp = c.to_int()
  cp >= hangul_v_base && cp < hangul_v_base + hangul_v_count
}

///|
/// Check if a character is a trailing consonant jamo (T)
/// Note: T_BASE (0x11A7) itself is not a valid trailing jamo
fn is_hangul_t(c : Char) -> Bool {
  let cp = c.to_int()
  cp > hangul_t_base && cp < hangul_t_base + hangul_t_count
}

///|
/// Check if a character is an LV syllable (no trailing consonant)
fn is_hangul_lv(c : Char) -> Bool {
  if !is_hangul_syllable(c) {
    return false
  }
  (c.to_int() - hangul_s_base) % hangul_t_count == 0
}

///|
/// Algorithmically decompose a Hangul syllable into jamo
/// Returns L + V for LV syllables, L + V + T for LVT syllables
fn decompose_hangul(syllable : Char) -> Array[Char] {
  let s_index = syllable.to_int() - hangul_s_base
  let l = hangul_l_base + s_index / hangul_n_count
  let v = hangul_v_base + s_index % hangul_n_count / hangul_t_count
  let t_index = s_index % hangul_t_count
  if t_index == 0 {
    [l.unsafe_to_char(), v.unsafe_to_char()] // LV syllable
  } else {
    [
      l.unsafe_to_char(),
      v.unsafe_to_char(),
      (hangul_t_base + t_index).unsafe_to_char(),
    ] // LVT syllable
  }
}

///|
/// Try to compose two characters into a Hangul syllable
/// Returns Some(syllable) if composition is possible, None otherwise
fn try_compose_hangul(first : Char, second : Char) -> Char? {
  // L + V -> LV syllable
  if is_hangul_l(first) && is_hangul_v(second) {
    let l_index = first.to_int() - hangul_l_base
    let v_index = second.to_int() - hangul_v_base
    return Some(
      (hangul_s_base + (l_index * hangul_v_count + v_index) * hangul_t_count).unsafe_to_char(),
    )
  }
  // LV + T -> LVT syllable
  if is_hangul_lv(first) && is_hangul_t(second) {
    return Some(
      (first.to_int() + (second.to_int() - hangul_t_base)).unsafe_to_char(),
    )
  }
  None
}
