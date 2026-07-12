///|
/// Unicode Normalization Conformance Tests - Part0
/// Generated from NormalizationTest.txt (Unicode 16.0.0)
///
/// Specific cases
///
/// Each test case contains 5 strings (c1, c2, c3, c4, c5) and must satisfy:
/// - NFC: c2 == NFC(c1) == NFC(c2) == NFC(c3)
/// - NFD: c3 == NFD(c1) == NFD(c2) == NFD(c3)
/// - NFKC: c4 == NFKC(c1) == NFKC(c2) == NFKC(c3) == NFKC(c4) == NFKC(c5)
/// - NFKD: c5 == NFKD(c1) == NFKD(c2) == NFKD(c3) == NFKD(c4) == NFKD(c5)

///|
/// Test data from NormalizationTest.txt (Part0: Specific cases)
/// Format: (c1, c2, c3, c4, c5)
let conformance_test_data_part0 : Array[
  (String, String, String, String, String),
] = [
  ("\u{1E0A}", "\u{1E0A}", "\u{0044}\u{0307}", "\u{1E0A}", "\u{0044}\u{0307}"),
  ("\u{1E0C}", "\u{1E0C}", "\u{0044}\u{0323}", "\u{1E0C}", "\u{0044}\u{0323}"),
  (
    "\u{1E0A}\u{0323}", "\u{1E0C}\u{0307}", "\u{0044}\u{0323}\u{0307}", "\u{1E0C}\u{0307}",
    "\u{0044}\u{0323}\u{0307}",
  ),
  (
    "\u{1E0C}\u{0307}", "\u{1E0C}\u{0307}", "\u{0044}\u{0323}\u{0307}", "\u{1E0C}\u{0307}",
    "\u{0044}\u{0323}\u{0307}",
  ),
  (
    "\u{0044}\u{0307}\u{0323}", "\u{1E0C}\u{0307}", "\u{0044}\u{0323}\u{0307}", "\u{1E0C}\u{0307}",
    "\u{0044}\u{0323}\u{0307}",
  ),
  (
    "\u{0044}\u{0323}\u{0307}", "\u{1E0C}\u{0307}", "\u{0044}\u{0323}\u{0307}", "\u{1E0C}\u{0307}",
    "\u{0044}\u{0323}\u{0307}",
  ),
  (
    "\u{1E0A}\u{031B}", "\u{1E0A}\u{031B}", "\u{0044}\u{031B}\u{0307}", "\u{1E0A}\u{031B}",
    "\u{0044}\u{031B}\u{0307}",
  ),
  (
    "\u{1E0C}\u{031B}", "\u{1E0C}\u{031B}", "\u{0044}\u{031B}\u{0323}", "\u{1E0C}\u{031B}",
    "\u{0044}\u{031B}\u{0323}",
  ),
  (
    "\u{1E0A}\u{031B}\u{0323}", "\u{1E0C}\u{031B}\u{0307}", "\u{0044}\u{031B}\u{0323}\u{0307}",
    "\u{1E0C}\u{031B}\u{0307}", "\u{0044}\u{031B}\u{0323}\u{0307}",
  ),
  (
    "\u{1E0C}\u{031B}\u{0307}", "\u{1E0C}\u{031B}\u{0307}", "\u{0044}\u{031B}\u{0323}\u{0307}",
    "\u{1E0C}\u{031B}\u{0307}", "\u{0044}\u{031B}\u{0323}\u{0307}",
  ),
  (
    "\u{0044}\u{031B}\u{0307}\u{0323}", "\u{1E0C}\u{031B}\u{0307}", "\u{0044}\u{031B}\u{0323}\u{0307}",
    "\u{1E0C}\u{031B}\u{0307}", "\u{0044}\u{031B}\u{0323}\u{0307}",
  ),
  (
    "\u{0044}\u{031B}\u{0323}\u{0307}", "\u{1E0C}\u{031B}\u{0307}", "\u{0044}\u{031B}\u{0323}\u{0307}",
    "\u{1E0C}\u{031B}\u{0307}", "\u{0044}\u{031B}\u{0323}\u{0307}",
  ),
  ("\u{00C8}", "\u{00C8}", "\u{0045}\u{0300}", "\u{00C8}", "\u{0045}\u{0300}"),
  ("\u{0112}", "\u{0112}", "\u{0045}\u{0304}", "\u{0112}", "\u{0045}\u{0304}"),
  (
    "\u{0045}\u{0300}", "\u{00C8}", "\u{0045}\u{0300}", "\u{00C8}", "\u{0045}\u{0300}",
  ),
  (
    "\u{0045}\u{0304}", "\u{0112}", "\u{0045}\u{0304}", "\u{0112}", "\u{0045}\u{0304}",
  ),
  (
    "\u{1E14}", "\u{1E14}", "\u{0045}\u{0304}\u{0300}", "\u{1E14}", "\u{0045}\u{0304}\u{0300}",
  ),
  (
    "\u{0112}\u{0300}", "\u{1E14}", "\u{0045}\u{0304}\u{0300}", "\u{1E14}", "\u{0045}\u{0304}\u{0300}",
  ),
  (
    "\u{1E14}\u{0304}", "\u{1E14}\u{0304}", "\u{0045}\u{0304}\u{0300}\u{0304}", "\u{1E14}\u{0304}",
    "\u{0045}\u{0304}\u{0300}\u{0304}",
  ),
  (
    "\u{0045}\u{0304}\u{0300}", "\u{1E14}", "\u{0045}\u{0304}\u{0300}", "\u{1E14}",
    "\u{0045}\u{0304}\u{0300}",
  ),
  (
    "\u{0045}\u{0300}\u{0304}", "\u{00C8}\u{0304}", "\u{0045}\u{0300}\u{0304}", "\u{00C8}\u{0304}",
    "\u{0045}\u{0300}\u{0304}",
  ),
  (
    "\u{05B8}\u{05B9}\u{05B1}\u{0591}\u{05C3}\u{05B0}\u{05AC}\u{059F}", "\u{05B1}\u{05B8}\u{05B9}\u{0591}\u{05C3}\u{05B0}\u{05AC}\u{059F}",
    "\u{05B1}\u{05B8}\u{05B9}\u{0591}\u{05C3}\u{05B0}\u{05AC}\u{059F}", "\u{05B1}\u{05B8}\u{05B9}\u{0591}\u{05C3}\u{05B0}\u{05AC}\u{059F}",
    "\u{05B1}\u{05B8}\u{05B9}\u{0591}\u{05C3}\u{05B0}\u{05AC}\u{059F}",
  ),
  (
    "\u{0592}\u{05B7}\u{05BC}\u{05A5}\u{05B0}\u{05C0}\u{05C4}\u{05AD}", "\u{05B0}\u{05B7}\u{05BC}\u{05A5}\u{0592}\u{05C0}\u{05AD}\u{05C4}",
    "\u{05B0}\u{05B7}\u{05BC}\u{05A5}\u{0592}\u{05C0}\u{05AD}\u{05C4}", "\u{05B0}\u{05B7}\u{05BC}\u{05A5}\u{0592}\u{05C0}\u{05AD}\u{05C4}",
    "\u{05B0}\u{05B7}\u{05BC}\u{05A5}\u{0592}\u{05C0}\u{05AD}\u{05C4}",
  ),
  (
    "\u{1100}\u{AC00}\u{11A8}", "\u{1100}\u{AC01}", "\u{1100}\u{1100}\u{1161}\u{11A8}",
    "\u{1100}\u{AC01}", "\u{1100}\u{1100}\u{1161}\u{11A8}",
  ),
  (
    "\u{1100}\u{AC00}\u{11A8}\u{11A8}", "\u{1100}\u{AC01}\u{11A8}", "\u{1100}\u{1100}\u{1161}\u{11A8}\u{11A8}",
    "\u{1100}\u{AC01}\u{11A8}", "\u{1100}\u{1100}\u{1161}\u{11A8}\u{11A8}",
  ),
  (
    "\u{01C4}\u{0323}", "\u{01C4}\u{0323}", "\u{01C4}\u{0323}", "\u{0044}\u{1E92}\u{030C}",
    "\u{0044}\u{005A}\u{0323}\u{030C}",
  ),
  (
    "\u{01C5}\u{0323}", "\u{01C5}\u{0323}", "\u{01C5}\u{0323}", "\u{0044}\u{1E93}\u{030C}",
    "\u{0044}\u{007A}\u{0323}\u{030C}",
  ),
  (
    "\u{01C6}\u{0323}", "\u{01C6}\u{0323}", "\u{01C6}\u{0323}", "\u{0064}\u{1E93}\u{030C}",
    "\u{0064}\u{007A}\u{0323}\u{030C}",
  ),
  (
    "\u{0DDD}\u{0334}", "\u{0DDD}\u{0334}", "\u{0DD9}\u{0DCF}\u{0334}\u{0DCA}", "\u{0DDD}\u{0334}",
    "\u{0DD9}\u{0DCF}\u{0334}\u{0DCA}",
  ),
  (
    "\u{3304}\u{0334}", "\u{3304}\u{0334}", "\u{3304}\u{0334}", "\u{30A4}\u{30CB}\u{30F3}\u{30B0}\u{0334}",
    "\u{30A4}\u{30CB}\u{30F3}\u{30AF}\u{0334}\u{3099}",
  ),
  (
    "\u{3307}\u{0334}", "\u{3307}\u{0334}", "\u{3307}\u{0334}", "\u{30A8}\u{30B9}\u{30AF}\u{30FC}\u{30C9}\u{0334}",
    "\u{30A8}\u{30B9}\u{30AF}\u{30FC}\u{30C8}\u{0334}\u{3099}",
  ),
  (
    "\u{3310}\u{0334}", "\u{3310}\u{0334}", "\u{3310}\u{0334}", "\u{30AE}\u{30AC}\u{0334}",
    "\u{30AD}\u{3099}\u{30AB}\u{0334}\u{3099}",
  ),
  (
    "\u{331E}\u{0334}", "\u{331E}\u{0334}", "\u{331E}\u{0334}", "\u{30B3}\u{30FC}\u{30DD}\u{0334}",
    "\u{30B3}\u{30FC}\u{30DB}\u{0334}\u{309A}",
  ),
  (
    "\u{3321}\u{0334}", "\u{3321}\u{0334}", "\u{3321}\u{0334}", "\u{30B7}\u{30EA}\u{30F3}\u{30B0}\u{0334}",
    "\u{30B7}\u{30EA}\u{30F3}\u{30AF}\u{0334}\u{3099}",
  ),
  (
    "\u{3332}\u{0334}", "\u{3332}\u{0334}", "\u{3332}\u{0334}", "\u{30D5}\u{30A1}\u{30E9}\u{30C3}\u{30C9}\u{0334}",
    "\u{30D5}\u{30A1}\u{30E9}\u{30C3}\u{30C8}\u{0334}\u{3099}",
  ),
  (
    "\u{333B}\u{0334}", "\u{333B}\u{0334}", "\u{333B}\u{0334}", "\u{30DA}\u{30FC}\u{30B8}\u{0334}",
    "\u{30D8}\u{309A}\u{30FC}\u{30B7}\u{0334}\u{3099}",
  ),
  (
    "\u{3340}\u{0334}", "\u{3340}\u{0334}", "\u{3340}\u{0334}", "\u{30DD}\u{30F3}\u{30C9}\u{0334}",
    "\u{30DB}\u{309A}\u{30F3}\u{30C8}\u{0334}\u{3099}",
  ),
  (
    "\u{334B}\u{0334}", "\u{334B}\u{0334}", "\u{334B}\u{0334}", "\u{30E1}\u{30AC}\u{0334}",
    "\u{30E1}\u{30AB}\u{0334}\u{3099}",
  ),
  (
    "\u{334E}\u{0334}", "\u{334E}\u{0334}", "\u{334E}\u{0334}", "\u{30E4}\u{30FC}\u{30C9}\u{0334}",
    "\u{30E4}\u{30FC}\u{30C8}\u{0334}\u{3099}",
  ),
  (
    "\u{FEF5}\u{0656}", "\u{FEF5}\u{0656}", "\u{FEF5}\u{0656}", "\u{0644}\u{0622}\u{0656}",
    "\u{0644}\u{0627}\u{0656}\u{0653}",
  ),
  (
    "\u{FEF6}\u{0656}", "\u{FEF6}\u{0656}", "\u{FEF6}\u{0656}", "\u{0644}\u{0622}\u{0656}",
    "\u{0644}\u{0627}\u{0656}\u{0653}",
  ),
  (
    "\u{FEF7}\u{0656}", "\u{FEF7}\u{0656}", "\u{FEF7}\u{0656}", "\u{0644}\u{0623}\u{0656}",
    "\u{0644}\u{0627}\u{0656}\u{0654}",
  ),
  (
    "\u{FEF8}\u{0656}", "\u{FEF8}\u{0656}", "\u{FEF8}\u{0656}", "\u{0644}\u{0623}\u{0656}",
    "\u{0644}\u{0627}\u{0656}\u{0654}",
  ),
  (
    "\u{FEF9}\u{0334}", "\u{FEF9}\u{0334}", "\u{FEF9}\u{0334}", "\u{0644}\u{0625}\u{0334}",
    "\u{0644}\u{0627}\u{0334}\u{0655}",
  ),
  (
    "\u{FEFA}\u{0334}", "\u{FEFA}\u{0334}", "\u{FEFA}\u{0334}", "\u{0644}\u{0625}\u{0334}",
    "\u{0644}\u{0627}\u{0334}\u{0655}",
  ),
]

///|
test "conformance: NormalizationTest.txt Part0 - NFC" {
  for i, t in conformance_test_data_part0 {
    let (c1, c2, c3, _, _) = t
    // NFC invariants: c2 == NFC(c1) == NFC(c2) == NFC(c3)
    let nfc_c1 = @normalization.nfc(c1)
    let nfc_c2 = @normalization.nfc(c2)
    let nfc_c3 = @normalization.nfc(c3)
    assert_eq(nfc_c1, c2, msg="NFC(c1) != c2 at index \{i}")
    assert_eq(nfc_c2, c2, msg="NFC(c2) != c2 at index \{i}")
    assert_eq(nfc_c3, c2, msg="NFC(c3) != c2 at index \{i}")
  }
}

///|
test "conformance: NormalizationTest.txt Part0 - NFD" {
  for i, t in conformance_test_data_part0 {
    let (c1, c2, c3, _, _) = t
    // NFD invariants: c3 == NFD(c1) == NFD(c2) == NFD(c3)
    let nfd_c1 = @normalization.nfd(c1)
    let nfd_c2 = @normalization.nfd(c2)
    let nfd_c3 = @normalization.nfd(c3)
    assert_eq(nfd_c1, c3, msg="NFD(c1) != c3 at index \{i}")
    assert_eq(nfd_c2, c3, msg="NFD(c2) != c3 at index \{i}")
    assert_eq(nfd_c3, c3, msg="NFD(c3) != c3 at index \{i}")
  }
}

///|
test "conformance: NormalizationTest.txt Part0 - NFKC" {
  for i, t in conformance_test_data_part0 {
    let (c1, c2, c3, c4, c5) = t
    // NFKC invariants: c4 == NFKC(c1) == NFKC(c2) == NFKC(c3) == NFKC(c4) == NFKC(c5)
    let nfkc_c1 = @normalization.nfkc(c1)
    let nfkc_c2 = @normalization.nfkc(c2)
    let nfkc_c3 = @normalization.nfkc(c3)
    let nfkc_c4 = @normalization.nfkc(c4)
    let nfkc_c5 = @normalization.nfkc(c5)
    assert_eq(nfkc_c1, c4, msg="NFKC(c1) != c4 at index \{i}")
    assert_eq(nfkc_c2, c4, msg="NFKC(c2) != c4 at index \{i}")
    assert_eq(nfkc_c3, c4, msg="NFKC(c3) != c4 at index \{i}")
    assert_eq(nfkc_c4, c4, msg="NFKC(c4) != c4 at index \{i}")
    assert_eq(nfkc_c5, c4, msg="NFKC(c5) != c4 at index \{i}")
  }
}

///|
test "conformance: NormalizationTest.txt Part0 - NFKD" {
  for i, t in conformance_test_data_part0 {
    let (c1, c2, c3, c4, c5) = t
    // NFKD invariants: c5 == NFKD(c1) == NFKD(c2) == NFKD(c3) == NFKD(c4) == NFKD(c5)
    let nfkd_c1 = @normalization.nfkd(c1)
    let nfkd_c2 = @normalization.nfkd(c2)
    let nfkd_c3 = @normalization.nfkd(c3)
    let nfkd_c4 = @normalization.nfkd(c4)
    let nfkd_c5 = @normalization.nfkd(c5)
    assert_eq(nfkd_c1, c5, msg="NFKD(c1) != c5 at index \{i}")
    assert_eq(nfkd_c2, c5, msg="NFKD(c2) != c5 at index \{i}")
    assert_eq(nfkd_c3, c5, msg="NFKD(c3) != c5 at index \{i}")
    assert_eq(nfkd_c4, c5, msg="NFKD(c4) != c5 at index \{i}")
    assert_eq(nfkd_c5, c5, msg="NFKD(c5) != c5 at index \{i}")
  }
}
