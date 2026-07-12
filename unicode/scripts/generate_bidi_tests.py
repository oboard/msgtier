#!/usr/bin/env python3
"""
Generate MoonBit conformance tests from Unicode BidiTest.txt and BidiCharacterTest.txt.

This script downloads and parses the official Unicode bidi test files and generates
MoonBit test files that verify the bidi implementation against the official test suite.

Test files:
- BidiTest.txt: Tests using bidi class names (L, R, AL, etc.)
- BidiCharacterTest.txt: Tests using actual character code points
"""

import argparse
import glob
import json
import shutil
import urllib.request
from pathlib import Path

# Unicode data URLs
UNICODE_VERSION = "16.0.0"
BIDI_TEST_URL = f"https://www.unicode.org/Public/{UNICODE_VERSION}/ucd/BidiTest.txt"
BIDI_CHARACTER_TEST_URL = f"https://www.unicode.org/Public/{UNICODE_VERSION}/ucd/BidiCharacterTest.txt"

# Map bidi class names to representative characters
CLASS_TO_CHAR = {
    "L": 0x0061,    # 'a' - Left-to-Right
    "R": 0x05D0,    # Hebrew Alef - Right-to-Left
    "AL": 0x0627,   # Arabic Alif - Arabic Letter
    "EN": 0x0030,   # '0' - European Number
    "ES": 0x002B,   # '+' - European Separator
    "ET": 0x0024,   # '$' - European Terminator
    "AN": 0x0660,   # Arabic-Indic 0 - Arabic Number
    "CS": 0x002C,   # ',' - Common Separator
    "NSM": 0x0300,  # Combining grave - Non-Spacing Mark
    "BN": 0x200B,   # Zero-width space - Boundary Neutral
    "B": 0x000A,    # Line feed - Paragraph Separator
    "S": 0x0009,    # Tab - Segment Separator
    "WS": 0x0020,   # Space - Whitespace
    "ON": 0x0021,   # '!' - Other Neutral
    "LRE": 0x202A,  # Left-to-Right Embedding
    "LRO": 0x202D,  # Left-to-Right Override
    "RLE": 0x202B,  # Right-to-Left Embedding
    "RLO": 0x202E,  # Right-to-Left Override
    "PDF": 0x202C,  # Pop Directional Formatting
    "LRI": 0x2066,  # Left-to-Right Isolate
    "RLI": 0x2067,  # Right-to-Left Isolate
    "FSI": 0x2068,  # First Strong Isolate
    "PDI": 0x2069,  # Pop Directional Isolate
}


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


def classes_to_moonbit_string(classes: list[str]) -> str:
    """Convert a list of bidi class names to a MoonBit string literal."""
    result = ""
    for cls in classes:
        if cls not in CLASS_TO_CHAR:
            raise ValueError(f"Unknown bidi class: {cls}")
        cp = CLASS_TO_CHAR[cls]
        result += f"\\u{{{cp:04X}}}"
    return result


def parse_levels(levels_str: str) -> list[int | None]:
    """Parse a space-separated levels string, returning None for 'x'."""
    if not levels_str.strip():
        return []
    result = []
    for part in levels_str.strip().split():
        if part.lower() == 'x':
            result.append(None)
        else:
            result.append(int(part))
    return result


def parse_reorder(reorder_str: str) -> list[int]:
    """Parse a space-separated reorder string."""
    if not reorder_str.strip():
        return []
    return [int(x) for x in reorder_str.strip().split()]


def parse_bidi_test(content: str) -> list[tuple]:
    """
    Parse BidiTest.txt.

    Returns list of (classes, bitset, expected_levels, expected_reorder) tuples.
    """
    tests = []
    current_levels = []
    current_reorder = []

    for line in content.strip().split("\n"):
        line = line.strip()

        # Skip comments and empty lines
        if not line or line.startswith("#"):
            continue

        # Handle @Levels marker
        if line.startswith("@Levels:"):
            levels_str = line[len("@Levels:"):].strip()
            current_levels = parse_levels(levels_str)
            continue

        # Handle @Reorder marker
        if line.startswith("@Reorder:"):
            reorder_str = line[len("@Reorder:"):].strip()
            current_reorder = parse_reorder(reorder_str)
            continue

        # Skip other @ lines (forward compatibility)
        if line.startswith("@"):
            continue

        # Parse data line: "L R AL; 7"
        if ";" not in line:
            continue

        parts = line.split(";")
        if len(parts) < 2:
            continue

        classes_str = parts[0].strip()
        bitset_str = parts[1].strip()

        # Parse classes
        classes = classes_str.split()
        if not classes:
            continue

        # Parse bitset (hex or decimal)
        try:
            bitset = int(bitset_str)
        except ValueError:
            continue

        tests.append((classes, bitset, list(current_levels), list(current_reorder)))

    return tests


def parse_bidi_character_test(content: str) -> list[tuple]:
    """
    Parse BidiCharacterTest.txt.

    Each line has 5 fields:
    - Field 0: Hex code points
    - Field 1: Paragraph direction (0=LTR, 1=RTL, 2=auto)
    - Field 2: Resolved paragraph level
    - Field 3: Resolved levels (space-separated, 'x' for removed)
    - Field 4: Visual reorder indices

    Returns list of (codepoints, para_dir, base_level, levels, reorder) tuples.
    """
    tests = []

    for line in content.strip().split("\n"):
        line = line.strip()

        # Skip comments and empty lines
        if not line or line.startswith("#"):
            continue

        parts = [p.strip() for p in line.split(";")]
        if len(parts) < 5:
            continue

        codepoints_str = parts[0]
        para_dir = int(parts[1])
        base_level = int(parts[2])
        levels = parse_levels(parts[3])
        reorder = parse_reorder(parts[4])

        # Convert codepoints to list
        codepoints = [int(cp, 16) for cp in codepoints_str.split()]

        tests.append((codepoints, para_dir, base_level, levels, reorder))

    return tests


def levels_to_moonbit_array(levels: list[int | None]) -> str:
    """Convert levels list to MoonBit array literal, using -1 for None (x)."""
    parts = [str(l) if l is not None else "-1" for l in levels]
    return "[" + ", ".join(parts) + "]"


def reorder_to_moonbit_array(reorder: list[int]) -> str:
    """Convert reorder list to MoonBit array literal."""
    return "[" + ", ".join(str(i) for i in reorder) + "]"


def codepoints_to_moonbit_string(codepoints: list[int]) -> str:
    """Convert codepoints list to MoonBit string literal."""
    result = ""
    for cp in codepoints:
        result += f"\\u{{{cp:04X}}}"
    return result


def generate_bidi_test_mbt(tests: list[tuple], output_dir: Path, part_size: int = 500):
    """
    Generate conformance test files from BidiTest.txt data.

    Creates separate subpackages for each part to allow independent compilation.
    """
    # Expand tests by bitset (1=auto, 2=LTR, 4=RTL)
    expanded_tests = []
    for classes, bitset, expected_levels, expected_reorder in tests:
        # Map bitset to paragraph levels
        if bitset & 1:  # auto-LTR
            expanded_tests.append((classes, -1, expected_levels, expected_reorder))
        if bitset & 2:  # LTR
            expanded_tests.append((classes, 0, expected_levels, expected_reorder))
        if bitset & 4:  # RTL
            expanded_tests.append((classes, 1, expected_levels, expected_reorder))

    print(f"Expanded to {len(expanded_tests)} test cases")

    # Split into parts
    parts = []
    for i in range(0, len(expanded_tests), part_size):
        parts.append(expanded_tests[i:i+part_size])

    # Create conformance directory structure
    conformance_dir = output_dir / "internal" / "conformance"
    bidi_conformance_dir = conformance_dir / "bidi"
    bidi_conformance_dir.mkdir(parents=True, exist_ok=True)

    total_cases = 0
    for part_num, part_tests in enumerate(parts):
        # Create subpackage directory
        part_dir = bidi_conformance_dir / f"part{part_num}"
        part_dir.mkdir(exist_ok=True)

        # Generate moon.pkg.json with test-import (only used in tests)
        pkg_json = {
            "test-import": [
                {
                    "path": "oboard/msgtier/unicode/bidi",
                    "alias": "bidi"
                }
            ]
        }
        (part_dir / "moon.pkg.json").write_text(json.dumps(pkg_json, indent=2) + "\n")

        code = f'''///|
/// Unicode Bidi Algorithm Conformance Tests - BidiTest.txt Part {part_num}
/// Generated from BidiTest.txt (Unicode {UNICODE_VERSION})
///
/// Tests the implementation against official Unicode bidi test data.
/// Each test verifies resolved embedding levels and visual reordering.

'''

        for i, (classes, para_level, expected_levels, expected_reorder) in enumerate(part_tests):
            input_str = classes_to_moonbit_string(classes)
            levels_arr = levels_to_moonbit_array(expected_levels)
            reorder_arr = reorder_to_moonbit_array(expected_reorder)

            code += f'''///|
test "{i}" {{
  let input = "{input_str}"
  let para_level = {para_level}
  let expected_levels = {levels_arr}
  let expected_reorder = {reorder_arr}

  // Process with appropriate paragraph level
  let result = if para_level < 0 {{
    @bidi.process(input)
  }} else {{
    @bidi.process_with_base_level(input, para_level)
  }}

  // Verify levels (skip 'x' positions marked as -1)
  for j = 0; j < expected_levels.length(); j = j + 1 {{
    if expected_levels[j] >= 0 {{
      assert_eq(result.levels[j], expected_levels[j])
    }}
  }}

  // Verify reordering
  let actual_reorder = @bidi.reorder(result)
  assert_eq(actual_reorder.length(), expected_reorder.length())
  for j = 0; j < expected_reorder.length(); j = j + 1 {{
    assert_eq(actual_reorder[j], expected_reorder[j])
  }}
}}

'''

        output_path = part_dir / "conformance_test.mbt"
        output_path.write_text(code)
        print(f"Generated {output_path} with {len(part_tests)} test cases")
        total_cases += len(part_tests)

    print(f"Generated {len(parts)} BidiTest.txt test subpackages with {total_cases} total test cases")


def generate_bidi_character_test_mbt(tests: list[tuple], output_dir: Path, part_size: int = 500):
    """
    Generate conformance test files from BidiCharacterTest.txt data.

    Creates separate subpackages for each part to allow independent compilation.
    """
    # Split into parts
    parts = []
    for i in range(0, len(tests), part_size):
        parts.append(tests[i:i+part_size])

    # Create conformance directory structure
    conformance_dir = output_dir / "internal" / "conformance"
    character_conformance_dir = conformance_dir / "character"
    character_conformance_dir.mkdir(parents=True, exist_ok=True)

    total_cases = 0
    for part_num, part_tests in enumerate(parts):
        # Create subpackage directory
        part_dir = character_conformance_dir / f"part{part_num}"
        part_dir.mkdir(exist_ok=True)

        # Generate moon.pkg.json with test-import (only used in tests)
        pkg_json = {
            "test-import": [
                {
                    "path": "oboard/msgtier/unicode/bidi",
                    "alias": "bidi"
                }
            ]
        }
        (part_dir / "moon.pkg.json").write_text(json.dumps(pkg_json, indent=2) + "\n")

        code = f'''///|
/// Unicode Bidi Algorithm Conformance Tests - BidiCharacterTest.txt Part {part_num}
/// Generated from BidiCharacterTest.txt (Unicode {UNICODE_VERSION})
///
/// Tests the implementation with actual Unicode characters including
/// bracket pairs and other character-specific behaviors.

'''

        for i, (codepoints, para_dir, base_level, levels, reorder) in enumerate(part_tests):
            input_str = codepoints_to_moonbit_string(codepoints)
            levels_arr = levels_to_moonbit_array(levels)
            reorder_arr = reorder_to_moonbit_array(reorder)

            code += f'''///|
test "{i}" {{
  let input = "{input_str}"
  let para_dir = {para_dir}
  let expected_base_level = {base_level}
  let expected_levels = {levels_arr}
  let expected_reorder = {reorder_arr}

  // Process with appropriate paragraph direction
  let result = match para_dir {{
    0 => @bidi.process_with_base_level(input, 0)  // LTR
    1 => @bidi.process_with_base_level(input, 1)  // RTL
    _ => @bidi.process(input)                      // Auto
  }}

  // Verify base level
  assert_eq(result.base_level, expected_base_level)

  // Verify levels (skip 'x' positions marked as -1)
  for j = 0; j < expected_levels.length(); j = j + 1 {{
    if expected_levels[j] >= 0 {{
      assert_eq(result.levels[j], expected_levels[j])
    }}
  }}

  // Verify reordering
  let actual_reorder = @bidi.reorder(result)
  assert_eq(actual_reorder.length(), expected_reorder.length())
  for j = 0; j < expected_reorder.length(); j = j + 1 {{
    assert_eq(actual_reorder[j], expected_reorder[j])
  }}
}}

'''

        output_path = part_dir / "conformance_test.mbt"
        output_path.write_text(code)
        print(f"Generated {output_path} with {len(part_tests)} test cases")
        total_cases += len(part_tests)

    print(f"Generated {len(parts)} BidiCharacterTest.txt test subpackages with {total_cases} total test cases")


def main():
    parser = argparse.ArgumentParser(description="Generate MoonBit bidi conformance tests")
    parser.add_argument(
        "--part-size",
        type=int,
        default=500,
        help="Number of tests per partition (default: 500)"
    )
    args = parser.parse_args()

    # Determine paths
    script_dir = Path(__file__).parent
    project_root = script_dir.parent
    cache_dir = script_dir / ".cache"
    bidi_dir = project_root / "bidi"

    cache_dir.mkdir(exist_ok=True)

    # Download test files
    bidi_test_data = download_file(BIDI_TEST_URL, cache_dir)
    bidi_char_test_data = download_file(BIDI_CHARACTER_TEST_URL, cache_dir)

    # Parse BidiTest.txt
    print("Parsing BidiTest.txt...")
    bidi_tests = parse_bidi_test(bidi_test_data)
    print(f"  Found {len(bidi_tests)} test cases")

    # Parse BidiCharacterTest.txt
    print("Parsing BidiCharacterTest.txt...")
    char_tests = parse_bidi_character_test(bidi_char_test_data)
    print(f"  Found {len(char_tests)} test cases")

    # Remove old generated test files and directories
    for pattern in ["conformance_biditest_*_test.mbt", "conformance_character*_test.mbt"]:
        for old_file in glob.glob(str(bidi_dir / pattern)):
            Path(old_file).unlink()
            print(f"Removed old {old_file}")

    # Remove old conformance subdirectories (both old and new locations)
    old_conformance_dir = bidi_dir / "conformance"
    if old_conformance_dir.exists():
        shutil.rmtree(old_conformance_dir)
        print(f"Removed old {old_conformance_dir}")

    new_conformance_dir = bidi_dir / "internal" / "conformance"
    if new_conformance_dir.exists():
        shutil.rmtree(new_conformance_dir)
        print(f"Removed old {new_conformance_dir}")

    # Generate MoonBit test files
    print(f"\nGenerating MoonBit test files with part_size={args.part_size}...")
    generate_bidi_test_mbt(bidi_tests, bidi_dir, part_size=args.part_size)
    generate_bidi_character_test_mbt(char_tests, bidi_dir, part_size=args.part_size)

    print("\nDone!")


if __name__ == "__main__":
    main()
