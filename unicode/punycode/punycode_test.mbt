///|
/// Tests for Punycode encoding/decoding (RFC 3492)

///|
test "encode: ASCII passthrough" {
  inspect(encode("abc"), content="abc-")
}

///|
test "encode: single non-ASCII" {
  // ü (U+00FC) -> "bcher" with encoded suffix
  inspect(encode("bücher"), content="bcher-kva")
}

///|
test "encode: München" {
  inspect(encode("München"), content="Mnchen-3ya")
}

///|
test "encode: Chinese" {
  // 中文 -> simplified Chinese characters
  inspect(encode("中文"), content="fiq228c")
}

///|
test "encode: Japanese" {
  // ドメイン -> Japanese katakana for "domain"
  inspect(encode("ドメイン"), content="eckwd4c7c")
}

///|
test "encode: Arabic" {
  // مثال -> Arabic example
  inspect(encode("مثال"), content="mgbh0fb")
}

///|
test "encode: mixed ASCII and non-ASCII" {
  inspect(encode("münchen"), content="mnchen-3ya")
}

///|
test "encode: empty string" {
  inspect(encode(""), content="")
}

///|
test "encode: pure ASCII" {
  inspect(encode("example"), content="example-")
}

///|
test "decode: ASCII passthrough" {
  inspect(decode("abc-"), content="abc")
}

///|
test "decode: single non-ASCII" {
  // bücher encodes to "bcher-kva"
  inspect(decode("bcher-kva"), content="bücher")
}

///|
test "decode: München" {
  inspect(decode("Mnchen-3ya"), content="München")
}

///|
test "decode: Chinese" {
  inspect(decode("fiq228c"), content="中文")
}

///|
test "decode: Japanese" {
  inspect(decode("eckwd4c7c"), content="ドメイン")
}

///|
test "decode: Arabic" {
  inspect(decode("mgbh0fb"), content="مثال")
}

///|
test "decode: mixed ASCII and non-ASCII" {
  inspect(decode("mnchen-3ya"), content="münchen")
}

///|
test "decode: empty string" {
  inspect(decode(""), content="")
}

///|
test "decode: pure ASCII" {
  inspect(decode("example-"), content="example")
}

///|
test "roundtrip: various strings" {
  let test_cases = [
    "hello", "münchen", "München", "中文", "日本語", "العربية", "한국어",
    "Привет", "",
  ]
  for tc in test_cases {
    let encoded = encode(tc)
    let decoded = decode(encoded)
    assert_eq(decoded, tc)
  }
}

///|
test "RFC 3492 examples: A (Arabic)" {
  // Example from RFC 3492 Section 7.1
  let arabic = "\u{0644}\u{064A}\u{0647}\u{0645}\u{0627}\u{0628}\u{062A}\u{0643}\u{0644}\u{0645}\u{0648}\u{0634}\u{0639}\u{0631}\u{0628}\u{064A}\u{061F}"
  inspect(encode(arabic), content="egbpdaj6bu4bxfgehfvwxn")
}

///|
test "RFC 3492 examples: B (Chinese simplified)" {
  // 他们为什么不说中文
  let chinese = "\u{4ED6}\u{4EEC}\u{4E3A}\u{4EC0}\u{4E48}\u{4E0D}\u{8BF4}\u{4E2D}\u{6587}"
  inspect(encode(chinese), content="ihqwcrb4cv8a8dqg056pqjye")
}

///|
test "RFC 3492 examples: C (Chinese traditional)" {
  // 他們爲什麽不說中文
  let chinese = "\u{4ED6}\u{5011}\u{7232}\u{4EC0}\u{9EBD}\u{4E0D}\u{8AAA}\u{4E2D}\u{6587}"
  inspect(encode(chinese), content="ihqwctvzc91f659drss3x8bo0yb")
}

///|
test "RFC 3492 examples: I (Japanese)" {
  // なぜみんな日本語を話してくれないのか
  let japanese = "\u{306A}\u{305C}\u{307F}\u{3093}\u{306A}\u{65E5}\u{672C}\u{8A9E}\u{3092}\u{8A71}\u{3057}\u{3066}\u{304F}\u{308C}\u{306A}\u{3044}\u{306E}\u{304B}"
  inspect(encode(japanese), content="n8jok5ay5dzabd5bym9f0cm5685rrjetr6pdxa")
}

///|
test "RFC 3492 examples: J (Korean)" {
  // 세계의모든사람들이한국어를이해한다면얼마나좋을까
  let korean = "\u{C138}\u{ACC4}\u{C758}\u{BAA8}\u{B4E0}\u{C0AC}\u{B78C}\u{B4E4}\u{C774}\u{D55C}\u{AD6D}\u{C5B4}\u{B97C}\u{C774}\u{D574}\u{D55C}\u{B2E4}\u{BA74}\u{C5BC}\u{B9C8}\u{B098}\u{C88B}\u{C744}\u{AE4C}"
  inspect(
    encode(korean),
    content="989aomsvi5e83db1d2a355cv1e0vak1dwrv93d5xbh15a0dt30a5jpsd879ccm6fea98c",
  )
}

///|
test "RFC 3492 examples: N (Spanish)" {
  // PorsijunopuedensimijhacarconelEspaol
  let spanish = "Porqu\u{00E9}nopuedensimplementehablarenEspa\u{00F1}ol"
  inspect(
    encode(spanish),
    content="PorqunopuedensimplementehablarenEspaol-fmd56a",
  )
}
