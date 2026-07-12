///|
/// Unicode Normalization Conformance Tests - Part5
/// Generated from NormalizationTest.txt (Unicode 16.0.0)
///
/// Chained primary composites
///
/// Each test case contains 5 strings (c1, c2, c3, c4, c5) and must satisfy:
/// - NFC: c2 == NFC(c1) == NFC(c2) == NFC(c3)
/// - NFD: c3 == NFD(c1) == NFD(c2) == NFD(c3)
/// - NFKC: c4 == NFKC(c1) == NFKC(c2) == NFKC(c3) == NFKC(c4) == NFKC(c5)
/// - NFKD: c5 == NFKD(c1) == NFKD(c2) == NFKD(c3) == NFKD(c4) == NFKD(c5)

///|
/// Test data from NormalizationTest.txt (Part5: Chained primary composites)
/// Format: (c1, c2, c3, c4, c5)
let conformance_test_data_part5 : Array[
  (String, String, String, String, String),
] = [
  (
    "\u{1138B}\u{113C7}", "\u{1138E}\u{113B8}", "\u{1138B}\u{113C2}\u{113B8}", "\u{1138E}\u{113B8}",
    "\u{1138B}\u{113C2}\u{113B8}",
  ),
  (
    "\u{113C2}\u{113C7}", "\u{113C5}\u{113B8}", "\u{113C2}\u{113C2}\u{113B8}", "\u{113C5}\u{113B8}",
    "\u{113C2}\u{113C2}\u{113B8}",
  ),
  (
    "\u{1138B}\u{113C5}", "\u{1138E}\u{113C2}", "\u{1138B}\u{113C2}\u{113C2}", "\u{1138E}\u{113C2}",
    "\u{1138B}\u{113C2}\u{113C2}",
  ),
  (
    "\u{1138B}\u{113C5}\u{113C2}", "\u{1138E}\u{113C5}", "\u{1138B}\u{113C2}\u{113C2}\u{113C2}",
    "\u{1138E}\u{113C5}", "\u{1138B}\u{113C2}\u{113C2}\u{113C2}",
  ),
  (
    "\u{1138B}\u{113C5}\u{113B8}", "\u{1138E}\u{113C7}", "\u{1138B}\u{113C2}\u{113C2}\u{113B8}",
    "\u{1138E}\u{113C7}", "\u{1138B}\u{113C2}\u{113C2}\u{113B8}",
  ),
  (
    "\u{1138B}\u{113C5}\u{113C9}", "\u{1138E}\u{113C8}", "\u{1138B}\u{113C2}\u{113C2}\u{113C9}",
    "\u{1138E}\u{113C8}", "\u{1138B}\u{113C2}\u{113C2}\u{113C9}",
  ),
  (
    "\u{113C2}\u{113C5}", "\u{113C5}\u{113C2}", "\u{113C2}\u{113C2}\u{113C2}", "\u{113C5}\u{113C2}",
    "\u{113C2}\u{113C2}\u{113C2}",
  ),
  (
    "\u{113C2}\u{113C5}\u{113C2}", "\u{113C5}\u{113C5}", "\u{113C2}\u{113C2}\u{113C2}\u{113C2}",
    "\u{113C5}\u{113C5}", "\u{113C2}\u{113C2}\u{113C2}\u{113C2}",
  ),
  (
    "\u{113C2}\u{113C5}\u{113B8}", "\u{113C5}\u{113C7}", "\u{113C2}\u{113C2}\u{113C2}\u{113B8}",
    "\u{113C5}\u{113C7}", "\u{113C2}\u{113C2}\u{113C2}\u{113B8}",
  ),
  (
    "\u{113C2}\u{113C5}\u{113C9}", "\u{113C5}\u{113C8}", "\u{113C2}\u{113C2}\u{113C2}\u{113C9}",
    "\u{113C5}\u{113C8}", "\u{113C2}\u{113C2}\u{113C2}\u{113C9}",
  ),
  (
    "\u{1138B}\u{113C8}", "\u{1138E}\u{113C9}", "\u{1138B}\u{113C2}\u{113C9}", "\u{1138E}\u{113C9}",
    "\u{1138B}\u{113C2}\u{113C9}",
  ),
  (
    "\u{113C2}\u{113C8}", "\u{113C5}\u{113C9}", "\u{113C2}\u{113C2}\u{113C9}", "\u{113C5}\u{113C9}",
    "\u{113C2}\u{113C2}\u{113C9}",
  ),
  (
    "\u{16121}\u{1611E}\u{1611F}", "\u{16121}\u{16123}", "\u{1611E}\u{1611E}\u{1611E}\u{1611F}",
    "\u{16121}\u{16123}", "\u{1611E}\u{1611E}\u{1611E}\u{1611F}",
  ),
  (
    "\u{16121}\u{16129}\u{1611F}", "\u{16121}\u{16124}", "\u{1611E}\u{1611E}\u{16129}\u{1611F}",
    "\u{16121}\u{16124}", "\u{1611E}\u{1611E}\u{16129}\u{1611F}",
  ),
  (
    "\u{16121}\u{1611E}\u{16120}", "\u{16121}\u{16125}", "\u{1611E}\u{1611E}\u{1611E}\u{16120}",
    "\u{16121}\u{16125}", "\u{1611E}\u{1611E}\u{1611E}\u{16120}",
  ),
  (
    "\u{1611E}\u{16121}", "\u{16121}\u{1611E}", "\u{1611E}\u{1611E}\u{1611E}", "\u{16121}\u{1611E}",
    "\u{1611E}\u{1611E}\u{1611E}",
  ),
  (
    "\u{1611E}\u{16121}\u{1611E}", "\u{16121}\u{16121}", "\u{1611E}\u{1611E}\u{1611E}\u{1611E}",
    "\u{16121}\u{16121}", "\u{1611E}\u{1611E}\u{1611E}\u{1611E}",
  ),
  (
    "\u{1611E}\u{16121}\u{16129}", "\u{16121}\u{16122}", "\u{1611E}\u{1611E}\u{1611E}\u{16129}",
    "\u{16121}\u{16122}", "\u{1611E}\u{1611E}\u{1611E}\u{16129}",
  ),
  (
    "\u{1611E}\u{16126}", "\u{16121}\u{16123}", "\u{1611E}\u{1611E}\u{1611E}\u{1611F}",
    "\u{16121}\u{16123}", "\u{1611E}\u{1611E}\u{1611E}\u{1611F}",
  ),
  (
    "\u{1611E}\u{16121}\u{1611F}", "\u{16121}\u{16123}", "\u{1611E}\u{1611E}\u{1611E}\u{1611F}",
    "\u{16121}\u{16123}", "\u{1611E}\u{1611E}\u{1611E}\u{1611F}",
  ),
  (
    "\u{1611E}\u{16128}", "\u{16121}\u{16125}", "\u{1611E}\u{1611E}\u{1611E}\u{16120}",
    "\u{16121}\u{16125}", "\u{1611E}\u{1611E}\u{1611E}\u{16120}",
  ),
  (
    "\u{1611E}\u{16121}\u{16120}", "\u{16121}\u{16125}", "\u{1611E}\u{1611E}\u{1611E}\u{16120}",
    "\u{16121}\u{16125}", "\u{1611E}\u{1611E}\u{1611E}\u{16120}",
  ),
  (
    "\u{1611E}\u{16121}\u{16123}", "\u{16121}\u{16126}", "\u{1611E}\u{1611E}\u{1611E}\u{1611E}\u{1611F}",
    "\u{16121}\u{16126}", "\u{1611E}\u{1611E}\u{1611E}\u{1611E}\u{1611F}",
  ),
  (
    "\u{1611E}\u{16121}\u{1611E}\u{1611F}", "\u{16121}\u{16126}", "\u{1611E}\u{1611E}\u{1611E}\u{1611E}\u{1611F}",
    "\u{16121}\u{16126}", "\u{1611E}\u{1611E}\u{1611E}\u{1611E}\u{1611F}",
  ),
  (
    "\u{1611E}\u{16121}\u{16124}", "\u{16121}\u{16127}", "\u{1611E}\u{1611E}\u{1611E}\u{16129}\u{1611F}",
    "\u{16121}\u{16127}", "\u{1611E}\u{1611E}\u{1611E}\u{16129}\u{1611F}",
  ),
  (
    "\u{1611E}\u{16121}\u{16129}\u{1611F}", "\u{16121}\u{16127}", "\u{1611E}\u{1611E}\u{1611E}\u{16129}\u{1611F}",
    "\u{16121}\u{16127}", "\u{1611E}\u{1611E}\u{1611E}\u{16129}\u{1611F}",
  ),
  (
    "\u{1611E}\u{16121}\u{16125}", "\u{16121}\u{16128}", "\u{1611E}\u{1611E}\u{1611E}\u{1611E}\u{16120}",
    "\u{16121}\u{16128}", "\u{1611E}\u{1611E}\u{1611E}\u{1611E}\u{16120}",
  ),
  (
    "\u{1611E}\u{16121}\u{1611E}\u{16120}", "\u{16121}\u{16128}", "\u{1611E}\u{1611E}\u{1611E}\u{1611E}\u{16120}",
    "\u{16121}\u{16128}", "\u{1611E}\u{1611E}\u{1611E}\u{1611E}\u{16120}",
  ),
  (
    "\u{1611E}\u{16127}", "\u{16121}\u{16124}", "\u{1611E}\u{1611E}\u{16129}\u{1611F}",
    "\u{16121}\u{16124}", "\u{1611E}\u{1611E}\u{16129}\u{1611F}",
  ),
  (
    "\u{1611E}\u{16122}\u{1611F}", "\u{16121}\u{16124}", "\u{1611E}\u{1611E}\u{16129}\u{1611F}",
    "\u{16121}\u{16124}", "\u{1611E}\u{1611E}\u{16129}\u{1611F}",
  ),
  (
    "\u{1611E}\u{16122}", "\u{16121}\u{16129}", "\u{1611E}\u{1611E}\u{16129}", "\u{16121}\u{16129}",
    "\u{1611E}\u{1611E}\u{16129}",
  ),
  (
    "\u{16D67}\u{16D68}", "\u{16D68}\u{16D67}", "\u{16D67}\u{16D67}\u{16D67}", "\u{16D68}\u{16D67}",
    "\u{16D67}\u{16D67}\u{16D67}",
  ),
  (
    "\u{16D67}\u{16D68}\u{16D67}", "\u{16D68}\u{16D68}", "\u{16D67}\u{16D67}\u{16D67}\u{16D67}",
    "\u{16D68}\u{16D68}", "\u{16D67}\u{16D67}\u{16D67}\u{16D67}",
  ),
  (
    "\u{16D63}\u{16D68}\u{16D67}", "\u{16D6A}\u{16D67}", "\u{16D63}\u{16D67}\u{16D67}\u{16D67}",
    "\u{16D6A}\u{16D67}", "\u{16D63}\u{16D67}\u{16D67}\u{16D67}",
  ),
  (
    "\u{16D69}\u{16D68}", "\u{16D6A}\u{16D67}", "\u{16D63}\u{16D67}\u{16D67}\u{16D67}",
    "\u{16D6A}\u{16D67}", "\u{16D63}\u{16D67}\u{16D67}\u{16D67}",
  ),
  (
    "\u{16D63}\u{16D67}\u{16D68}", "\u{16D6A}\u{16D67}", "\u{16D63}\u{16D67}\u{16D67}\u{16D67}",
    "\u{16D6A}\u{16D67}", "\u{16D63}\u{16D67}\u{16D67}\u{16D67}",
  ),
  (
    "\u{16D69}\u{16D68}\u{16D67}", "\u{16D6A}\u{16D68}", "\u{16D63}\u{16D67}\u{16D67}\u{16D67}\u{16D67}",
    "\u{16D6A}\u{16D68}", "\u{16D63}\u{16D67}\u{16D67}\u{16D67}\u{16D67}",
  ),
  (
    "\u{16D63}\u{16D67}\u{16D68}\u{16D67}", "\u{16D6A}\u{16D68}", "\u{16D63}\u{16D67}\u{16D67}\u{16D67}\u{16D67}",
    "\u{16D6A}\u{16D68}", "\u{16D63}\u{16D67}\u{16D67}\u{16D67}\u{16D67}",
  ),
]

///|
test "conformance: NormalizationTest.txt Part5 - NFC" {
  for i, t in conformance_test_data_part5 {
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
test "conformance: NormalizationTest.txt Part5 - NFD" {
  for i, t in conformance_test_data_part5 {
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
test "conformance: NormalizationTest.txt Part5 - NFKC" {
  for i, t in conformance_test_data_part5 {
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
test "conformance: NormalizationTest.txt Part5 - NFKD" {
  for i, t in conformance_test_data_part5 {
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
