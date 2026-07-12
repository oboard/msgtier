#!/usr/bin/env python3
"""
Generate MoonBit conformance tests from Unicode NormalizationTest.txt.

This script downloads and parses NormalizationTest.txt and generates
MoonBit test files that verify the normalization implementation
against the official Unicode test suite.

Test cases are grouped by the official @Part sections in the file:
- Part0: Specific cases
- Part1: Character by character test
- Part2: Canonical Order Test
- Part3: PRI #29 Test
- Part4: Canonical closures (excluding Hangul)
- Part5: Chained primary composites
"""

import glob
import urllib.request
from pathlib import Path


# Unicode data URL
UNICODE_VERSION = "16.0.0"
NORMALIZATION_TEST_URL = f"https://www.unicode.org/Public/{UNICODE_VERSION}/ucd/NormalizationTest.txt"


def download_file(url: str, cache_dir: Path) -> str:
    """Download a file and cache it locally."""
    filename = url.split("/")[-1]
    cache_path = cache_dir / filename

    if cache_path.exists():
        print(f"Using cached {filename}")
        return cache_path.read_text()

    print(f"Downloading {filename}...")
    with urllib.request.urlopen(url) as response:
        content = response.read().decode("utf-8")

    cache_path.write_text(content)
    return content


def hex_seq_to_moonbit_string(hex_seq: str) -> str:
    """
    Convert a hex code point sequence to a MoonBit string literal.

    Input: "0041 0307" (space-separated hex code points)
    Output: "\\u{0041}\\u{0307}"
    """
    if not hex_seq.strip():
        return ""

    parts = hex_seq.strip().split()
    result = ""
    for part in parts:
        cp = int(part, 16)
        result += f"\\u{{{cp:04X}}}"
    return result


def parse_normalization_test(content: str) -> dict[str, dict]:
    """
    Parse NormalizationTest.txt and return dict of sections.

    Each section contains:
    - name: Section description (e.g., "Specific cases")
    - cases: List of (c1, c2, c3, c4, c5) tuples as MoonBit string literals
    """
    sections = {}
    current_section = None

    for line in content.strip().split("\n"):
        line = line.strip()

        # Detect @Part markers
        if line.startswith("@Part"):
            # Extract section number and description
            # e.g., "@Part0 # Specific cases" -> ("Part0", "Specific cases")
            parts = line.split("#", 1)
            section_id = parts[0].strip()[1:]  # Remove @ prefix
            section_name = parts[1].strip() if len(parts) > 1 else ""
            sections[section_id] = {"name": section_name, "cases": []}
            current_section = section_id
            continue

        # Skip comments and empty lines
        if not line or line.startswith("#"):
            continue

        # Skip lines before the first @Part marker
        if current_section is None:
            continue

        # Remove trailing comment
        if "#" in line:
            line = line.split("#")[0].strip()

        # Split by semicolon
        parts = line.split(";")
        if len(parts) < 5:
            continue

        # Extract c1-c5 (first 5 columns)
        c1 = hex_seq_to_moonbit_string(parts[0])
        c2 = hex_seq_to_moonbit_string(parts[1])
        c3 = hex_seq_to_moonbit_string(parts[2])
        c4 = hex_seq_to_moonbit_string(parts[3])
        c5 = hex_seq_to_moonbit_string(parts[4])

        sections[current_section]["cases"].append((c1, c2, c3, c4, c5))

    return sections


def generate_conformance_test_mbt(sections: dict[str, dict], output_dir: Path):
    """Generate conformance test files, one per @Part section."""

    total_cases = 0

    for section_id, section_data in sections.items():
        section_name = section_data["name"]
        cases = section_data["cases"]

        if not cases:
            continue

        # Extract part number from section_id (e.g., "Part0" -> "0")
        part_num = section_id.replace("Part", "")

        code = f'''///|
/// Unicode Normalization Conformance Tests - {section_id}
/// Generated from NormalizationTest.txt (Unicode {UNICODE_VERSION})
///
/// {section_name}
///
/// Each test case contains 5 strings (c1, c2, c3, c4, c5) and must satisfy:
/// - NFC: c2 == NFC(c1) == NFC(c2) == NFC(c3)
/// - NFD: c3 == NFD(c1) == NFD(c2) == NFD(c3)
/// - NFKC: c4 == NFKC(c1) == NFKC(c2) == NFKC(c3) == NFKC(c4) == NFKC(c5)
/// - NFKD: c5 == NFKD(c1) == NFKD(c2) == NFKD(c3) == NFKD(c4) == NFKD(c5)

///|
/// Test data from NormalizationTest.txt ({section_id}: {section_name})
/// Format: (c1, c2, c3, c4, c5)
let conformance_test_data_part{part_num} : Array[(String, String, String, String, String)] = [
'''

        # Write test data
        for i, (c1, c2, c3, c4, c5) in enumerate(cases):
            if i > 0:
                code += ",\n"
            code += f'  ("{c1}", "{c2}", "{c3}", "{c4}", "{c5}")'

        code += f'''
]

///|
test "conformance: NormalizationTest.txt {section_id} - NFC" {{
  for i, t in conformance_test_data_part{part_num} {{
    let (c1, c2, c3, _, _) = t
    // NFC invariants: c2 == NFC(c1) == NFC(c2) == NFC(c3)
    let nfc_c1 = @normalization.nfc(c1)
    let nfc_c2 = @normalization.nfc(c2)
    let nfc_c3 = @normalization.nfc(c3)
    assert_eq(nfc_c1, c2, msg="NFC(c1) != c2 at index \\{{i}}")
    assert_eq(nfc_c2, c2, msg="NFC(c2) != c2 at index \\{{i}}")
    assert_eq(nfc_c3, c2, msg="NFC(c3) != c2 at index \\{{i}}")
  }}
}}

///|
test "conformance: NormalizationTest.txt {section_id} - NFD" {{
  for i, t in conformance_test_data_part{part_num} {{
    let (c1, c2, c3, _, _) = t
    // NFD invariants: c3 == NFD(c1) == NFD(c2) == NFD(c3)
    let nfd_c1 = @normalization.nfd(c1)
    let nfd_c2 = @normalization.nfd(c2)
    let nfd_c3 = @normalization.nfd(c3)
    assert_eq(nfd_c1, c3, msg="NFD(c1) != c3 at index \\{{i}}")
    assert_eq(nfd_c2, c3, msg="NFD(c2) != c3 at index \\{{i}}")
    assert_eq(nfd_c3, c3, msg="NFD(c3) != c3 at index \\{{i}}")
  }}
}}

///|
test "conformance: NormalizationTest.txt {section_id} - NFKC" {{
  for i, t in conformance_test_data_part{part_num} {{
    let (c1, c2, c3, c4, c5) = t
    // NFKC invariants: c4 == NFKC(c1) == NFKC(c2) == NFKC(c3) == NFKC(c4) == NFKC(c5)
    let nfkc_c1 = @normalization.nfkc(c1)
    let nfkc_c2 = @normalization.nfkc(c2)
    let nfkc_c3 = @normalization.nfkc(c3)
    let nfkc_c4 = @normalization.nfkc(c4)
    let nfkc_c5 = @normalization.nfkc(c5)
    assert_eq(nfkc_c1, c4, msg="NFKC(c1) != c4 at index \\{{i}}")
    assert_eq(nfkc_c2, c4, msg="NFKC(c2) != c4 at index \\{{i}}")
    assert_eq(nfkc_c3, c4, msg="NFKC(c3) != c4 at index \\{{i}}")
    assert_eq(nfkc_c4, c4, msg="NFKC(c4) != c4 at index \\{{i}}")
    assert_eq(nfkc_c5, c4, msg="NFKC(c5) != c4 at index \\{{i}}")
  }}
}}

///|
test "conformance: NormalizationTest.txt {section_id} - NFKD" {{
  for i, t in conformance_test_data_part{part_num} {{
    let (c1, c2, c3, c4, c5) = t
    // NFKD invariants: c5 == NFKD(c1) == NFKD(c2) == NFKD(c3) == NFKD(c4) == NFKD(c5)
    let nfkd_c1 = @normalization.nfkd(c1)
    let nfkd_c2 = @normalization.nfkd(c2)
    let nfkd_c3 = @normalization.nfkd(c3)
    let nfkd_c4 = @normalization.nfkd(c4)
    let nfkd_c5 = @normalization.nfkd(c5)
    assert_eq(nfkd_c1, c5, msg="NFKD(c1) != c5 at index \\{{i}}")
    assert_eq(nfkd_c2, c5, msg="NFKD(c2) != c5 at index \\{{i}}")
    assert_eq(nfkd_c3, c5, msg="NFKD(c3) != c5 at index \\{{i}}")
    assert_eq(nfkd_c4, c5, msg="NFKD(c4) != c5 at index \\{{i}}")
    assert_eq(nfkd_c5, c5, msg="NFKD(c5) != c5 at index \\{{i}}")
  }}
}}
'''

        # File names must end with _test.mbt to be recognized as test files
        output_path = output_dir / f"conformance_part{part_num}_test.mbt"
        output_path.write_text(code)
        print(f"Generated {output_path} ({section_name}) with {len(cases)} test cases")
        total_cases += len(cases)

    print(f"Generated {len(sections)} test files with {total_cases} total test cases")


def main():
    # Determine paths
    script_dir = Path(__file__).parent
    project_root = script_dir.parent
    cache_dir = script_dir / ".cache"
    normalization_dir = project_root / "normalization"

    cache_dir.mkdir(exist_ok=True)

    # Download test file
    test_data = download_file(NORMALIZATION_TEST_URL, cache_dir)

    # Parse test cases by section
    print("Parsing NormalizationTest.txt...")
    sections = parse_normalization_test(test_data)
    for section_id, section_data in sections.items():
        print(f"  {section_id}: {section_data['name']} ({len(section_data['cases'])} cases)")

    # Remove old generated test files
    for old_pattern in ["conformance_test.mbt", "conformance_test_part*.mbt", "conformance_part*_test.mbt"]:
        for old_file in glob.glob(str(normalization_dir / old_pattern)):
            Path(old_file).unlink()
            print(f"Removed old {old_file}")

    # Generate MoonBit test files (one per section)
    print("\nGenerating MoonBit test files...")
    generate_conformance_test_mbt(sections, normalization_dir)

    print("\nDone!")


if __name__ == "__main__":
    main()
