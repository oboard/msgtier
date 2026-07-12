#!/usr/bin/env python3
"""
Generate MoonBit source files for Unicode Bidirectional Algorithm (UAX #9).

This script downloads and parses:
- DerivedBidiClass.txt: Full Bidi_Class property (all 23 classes)
- BidiMirroring.txt: Bidi_Mirrored and Bidi_Mirroring_Glyph
- BidiBrackets.txt: Bidi_Paired_Bracket and Bidi_Paired_Bracket_Type

And generates:
- internal/bidi/bidi_class.mbt: Full Bidi_Class lookup
- internal/bidi/mirrored.mbt: Mirroring property lookup
- internal/bidi/bracket.mbt: Bracket pair lookup
"""

import os
import sys
import urllib.request
from pathlib import Path
from collections import defaultdict

# Unicode data URLs
UNICODE_VERSION = "16.0.0"
BIDI_CLASS_URL = f"https://www.unicode.org/Public/{UNICODE_VERSION}/ucd/extracted/DerivedBidiClass.txt"
BIDI_MIRRORING_URL = f"https://www.unicode.org/Public/{UNICODE_VERSION}/ucd/BidiMirroring.txt"
BIDI_BRACKETS_URL = f"https://www.unicode.org/Public/{UNICODE_VERSION}/ucd/BidiBrackets.txt"


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


def parse_range(range_str: str) -> tuple[int, int]:
    """Parse a code point range like '0000..001F' or single '0020'."""
    range_str = range_str.strip()
    if ".." in range_str:
        start, end = range_str.split("..")
        return int(start, 16), int(end, 16)
    else:
        cp = int(range_str, 16)
        return cp, cp


def parse_bidi_class(content: str) -> list[tuple]:
    """
    Parse DerivedBidiClass.txt.
    Returns list of (start, end, bidi_class).
    """
    entries = []

    for line in content.strip().split("\n"):
        if "#" in line:
            line = line.split("#")[0]
        line = line.strip()
        if not line:
            continue

        parts = [p.strip() for p in line.split(";")]
        if len(parts) < 2:
            continue

        start, end = parse_range(parts[0])
        bidi_class = parts[1].strip()

        entries.append((start, end, bidi_class))

    return entries


def parse_bidi_mirroring(content: str) -> list[tuple]:
    """
    Parse BidiMirroring.txt.
    Returns list of (code_point, mirrored_code_point).
    """
    entries = []

    for line in content.strip().split("\n"):
        if "#" in line:
            line = line.split("#")[0]
        line = line.strip()
        if not line:
            continue

        parts = [p.strip() for p in line.split(";")]
        if len(parts) < 2:
            continue

        cp = int(parts[0], 16)
        mirrored = int(parts[1], 16)

        entries.append((cp, mirrored))

    return entries


def parse_bidi_brackets(content: str) -> list[tuple]:
    """
    Parse BidiBrackets.txt.
    Returns list of (code_point, paired_bracket, bracket_type).
    bracket_type: 'o' for open, 'c' for close
    """
    entries = []

    for line in content.strip().split("\n"):
        if "#" in line:
            line = line.split("#")[0]
        line = line.strip()
        if not line:
            continue

        parts = [p.strip() for p in line.split(";")]
        if len(parts) < 3:
            continue

        cp = int(parts[0], 16)
        paired = int(parts[1], 16)
        bracket_type = parts[2].strip().lower()

        entries.append((cp, paired, bracket_type))

    return entries


def generate_bidi_class_mbt(entries: list[tuple], output_path: Path):
    """Generate bidi_class.mbt with full Bidi_Class lookup (all 23 classes)."""

    # All 23 Bidi classes from UAX #9
    bidi_map = {
        # Strong types
        "L": 0,     # Left-to-Right
        "R": 1,     # Right-to-Left
        "AL": 2,    # Arabic Letter

        # Weak types
        "EN": 3,    # European Number
        "ES": 4,    # European Separator
        "ET": 5,    # European Terminator
        "AN": 6,    # Arabic Number
        "CS": 7,    # Common Separator
        "NSM": 8,   # Non-Spacing Mark
        "BN": 9,    # Boundary Neutral

        # Neutral types
        "B": 10,    # Paragraph Separator
        "S": 11,    # Segment Separator
        "WS": 12,   # Whitespace
        "ON": 13,   # Other Neutral

        # Explicit formatting
        "LRE": 14,  # Left-to-Right Embedding
        "LRO": 15,  # Left-to-Right Override
        "RLE": 16,  # Right-to-Left Embedding
        "RLO": 17,  # Right-to-Left Override
        "PDF": 18,  # Pop Directional Formatting
        "LRI": 19,  # Left-to-Right Isolate
        "RLI": 20,  # Right-to-Left Isolate
        "FSI": 21,  # First Strong Isolate
        "PDI": 22,  # Pop Directional Isolate
    }

    # Filter and encode
    filtered_entries = [(start, end, bidi_map[bidi_class])
                        for start, end, bidi_class in entries
                        if bidi_class in bidi_map]
    filtered_entries.sort(key=lambda x: x[0])

    range_starts = [e[0] for e in filtered_entries]
    range_ends = [e[1] for e in filtered_entries]
    range_classes = [e[2] for e in filtered_entries]

    code = '''///|
/// Full Bidi_Class lookup for Unicode Bidirectional Algorithm (UAX #9)
/// Generated from DerivedBidiClass.txt

///|
/// All 23 Bidi_Class values from UAX #9
pub(all) enum BidiClass {
  // Strong types
  L    // Left-to-Right
  R    // Right-to-Left
  AL   // Arabic Letter

  // Weak types
  EN   // European Number
  ES   // European Separator
  ET   // European Terminator
  AN   // Arabic Number
  CS   // Common Separator
  NSM  // Non-Spacing Mark
  BN   // Boundary Neutral

  // Neutral types
  B    // Paragraph Separator
  S    // Segment Separator
  WS   // Whitespace
  ON   // Other Neutral

  // Explicit formatting
  LRE  // Left-to-Right Embedding
  LRO  // Left-to-Right Override
  RLE  // Right-to-Left Embedding
  RLO  // Right-to-Left Override
  PDF  // Pop Directional Formatting
  LRI  // Left-to-Right Isolate
  RLI  // Right-to-Left Isolate
  FSI  // First Strong Isolate
  PDI  // Pop Directional Isolate
} derive(Show, Eq)

///|
/// Range start code points
let bidi_range_starts : FixedArray[Int] = [
'''
    # Format in rows of 10
    for i, s in enumerate(range_starts):
        if i > 0 and i % 10 == 0:
            code += "\n"
        elif i > 0:
            code += " "
        code += f"0x{s:04X},"
    code = code.rstrip(",")
    code += "\n]\n\n"

    code += '''///|
/// Range end code points (inclusive)
let bidi_range_ends : FixedArray[Int] = [
'''
    for i, e in enumerate(range_ends):
        if i > 0 and i % 10 == 0:
            code += "\n"
        elif i > 0:
            code += " "
        code += f"0x{e:04X},"
    code = code.rstrip(",")
    code += "\n]\n\n"

    code += '''///|
/// Bidi class codes for each range
let bidi_range_classes : FixedArray[Int] = [
'''
    for i, c in enumerate(range_classes):
        if i > 0 and i % 20 == 0:
            code += "\n"
        elif i > 0:
            code += " "
        code += f"{c},"
    code = code.rstrip(",")
    code += "\n]\n\n"

    code += '''///|
/// Binary search for character in Bidi ranges
fn find_bidi_range(c : Char) -> Int {
  let cp = c.to_int()
  let mut left = 0
  let mut right = bidi_range_starts.length() - 1

  while left <= right {
    let mid = (left + right) / 2
    let start = bidi_range_starts[mid]
    let end = bidi_range_ends[mid]

    if cp < start {
      right = mid - 1
    } else if cp > end {
      left = mid + 1
    } else {
      return mid
    }
  }

  -1 // Not found
}

///|
/// Convert class code to BidiClass enum
fn bidi_from_code(code : Int) -> BidiClass {
  match code {
    0 => L
    1 => R
    2 => AL
    3 => EN
    4 => ES
    5 => ET
    6 => AN
    7 => CS
    8 => NSM
    9 => BN
    10 => B
    11 => S
    12 => WS
    13 => ON
    14 => LRE
    15 => LRO
    16 => RLE
    17 => RLO
    18 => PDF
    19 => LRI
    20 => RLI
    21 => FSI
    22 => PDI
    _ => L // Default to L for unknown
  }
}

///|
/// Look up Bidi_Class for a character
pub fn lookup_bidi_class(c : Char) -> BidiClass {
  let idx = find_bidi_range(c)
  if idx < 0 {
    return L // Default to L for characters not in table
  }
  bidi_from_code(bidi_range_classes[idx])
}

///|
/// Check if a character is a strong type (L, R, or AL)
pub fn is_strong(c : Char) -> Bool {
  match lookup_bidi_class(c) {
    L | R | AL => true
    _ => false
  }
}

///|
/// Check if a character is a strong RTL type (R or AL)
pub fn is_strong_rtl(c : Char) -> Bool {
  match lookup_bidi_class(c) {
    R | AL => true
    _ => false
  }
}

///|
/// Check if a character is an explicit formatting character
pub fn is_explicit_formatting(c : Char) -> Bool {
  match lookup_bidi_class(c) {
    LRE | LRO | RLE | RLO | PDF | LRI | RLI | FSI | PDI => true
    _ => false
  }
}

///|
/// Check if a character is an isolate initiator
pub fn is_isolate_initiator(c : Char) -> Bool {
  match lookup_bidi_class(c) {
    LRI | RLI | FSI => true
    _ => false
  }
}

///|
/// Check if Bidi class is a strong type
pub fn BidiClass::is_strong(self : BidiClass) -> Bool {
  match self {
    L | R | AL => true
    _ => false
  }
}

///|
/// Check if Bidi class is a strong RTL type
pub fn BidiClass::is_strong_rtl(self : BidiClass) -> Bool {
  match self {
    R | AL => true
    _ => false
  }
}

///|
/// Check if Bidi class is a weak type
pub fn BidiClass::is_weak(self : BidiClass) -> Bool {
  match self {
    EN | ES | ET | AN | CS | NSM | BN => true
    _ => false
  }
}

///|
/// Check if Bidi class is a neutral type
pub fn BidiClass::is_neutral(self : BidiClass) -> Bool {
  match self {
    B | S | WS | ON => true
    _ => false
  }
}

///|
/// Check if Bidi class is an explicit formatting type
pub fn BidiClass::is_explicit(self : BidiClass) -> Bool {
  match self {
    LRE | LRO | RLE | RLO | PDF | LRI | RLI | FSI | PDI => true
    _ => false
  }
}

///|
/// Check if Bidi class is an isolate initiator
pub fn BidiClass::is_isolate_initiator(self : BidiClass) -> Bool {
  match self {
    LRI | RLI | FSI => true
    _ => false
  }
}

///|
/// Check if Bidi class is a neutral or isolate type (for N rules)
pub fn BidiClass::is_neutral_or_isolate(self : BidiClass) -> Bool {
  match self {
    B | S | WS | ON | FSI | LRI | RLI | PDI => true
    _ => false
  }
}
'''

    output_path.write_text(code)
    print(f"Generated {output_path} with {len(range_starts)} Bidi ranges")


def generate_mirrored_mbt(entries: list[tuple], output_path: Path):
    """Generate mirrored.mbt with Bidi_Mirrored and Bidi_Mirroring_Glyph lookup."""

    # Sort by code point for binary search
    entries.sort(key=lambda x: x[0])

    code_points = [e[0] for e in entries]
    mirrored_glyphs = [e[1] for e in entries]

    code = '''///|
/// Bidi_Mirrored and Bidi_Mirroring_Glyph lookup for UAX #9
/// Generated from BidiMirroring.txt

///|
/// Code points with mirroring property
let mirrored_code_points : FixedArray[Int] = [
'''
    for i, cp in enumerate(code_points):
        if i > 0 and i % 10 == 0:
            code += "\n"
        elif i > 0:
            code += " "
        code += f"0x{cp:04X},"
    code = code.rstrip(",")
    code += "\n]\n\n"

    code += '''///|
/// Corresponding mirrored glyphs
let mirrored_glyphs : FixedArray[Int] = [
'''
    for i, mg in enumerate(mirrored_glyphs):
        if i > 0 and i % 10 == 0:
            code += "\n"
        elif i > 0:
            code += " "
        code += f"0x{mg:04X},"
    code = code.rstrip(",")
    code += "\n]\n\n"

    code += '''///|
/// Binary search for character in mirrored list
fn find_mirrored_index(c : Char) -> Int {
  let cp = c.to_int()
  let mut left = 0
  let mut right = mirrored_code_points.length() - 1

  while left <= right {
    let mid = (left + right) / 2
    let mid_cp = mirrored_code_points[mid]

    if cp < mid_cp {
      right = mid - 1
    } else if cp > mid_cp {
      left = mid + 1
    } else {
      return mid
    }
  }

  -1 // Not found
}

///|
/// Check if a character has the Bidi_Mirrored property
pub fn is_bidi_mirrored(c : Char) -> Bool {
  find_mirrored_index(c) >= 0
}

///|
/// Get the Bidi_Mirroring_Glyph for a character
/// Returns the mirrored character if it has one, otherwise returns the original
pub fn bidi_mirroring_glyph(c : Char) -> Char {
  let idx = find_mirrored_index(c)
  if idx < 0 {
    c
  } else {
    mirrored_glyphs[idx].unsafe_to_char()
  }
}
'''

    output_path.write_text(code)
    print(f"Generated {output_path} with {len(code_points)} mirrored characters")


def generate_bracket_mbt(entries: list[tuple], output_path: Path):
    """Generate bracket.mbt with Bidi_Paired_Bracket lookup."""

    # Sort by code point for binary search
    entries.sort(key=lambda x: x[0])

    code_points = [e[0] for e in entries]
    paired_brackets = [e[1] for e in entries]
    # 0 = open, 1 = close
    bracket_types = [0 if e[2] == 'o' else 1 for e in entries]

    code = '''///|
/// Bidi_Paired_Bracket lookup for UAX #9 N0 rule
/// Generated from BidiBrackets.txt

///|
/// Bracket type
pub(all) enum BracketType {
  Open   // Opening bracket
  Close  // Closing bracket
  None   // Not a bracket
} derive(Show, Eq)

///|
/// Code points of paired brackets
let bracket_code_points : FixedArray[Int] = [
'''
    for i, cp in enumerate(code_points):
        if i > 0 and i % 10 == 0:
            code += "\n"
        elif i > 0:
            code += " "
        code += f"0x{cp:04X},"
    code = code.rstrip(",")
    code += "\n]\n\n"

    code += '''///|
/// Paired bracket for each code point
let paired_brackets : FixedArray[Int] = [
'''
    for i, pb in enumerate(paired_brackets):
        if i > 0 and i % 10 == 0:
            code += "\n"
        elif i > 0:
            code += " "
        code += f"0x{pb:04X},"
    code = code.rstrip(",")
    code += "\n]\n\n"

    code += '''///|
/// Bracket types (0 = open, 1 = close)
let bracket_types : FixedArray[Int] = [
'''
    for i, bt in enumerate(bracket_types):
        if i > 0 and i % 20 == 0:
            code += "\n"
        elif i > 0:
            code += " "
        code += f"{bt},"
    code = code.rstrip(",")
    code += "\n]\n\n"

    code += '''///|
/// Binary search for character in bracket list
fn find_bracket_index(c : Char) -> Int {
  let cp = c.to_int()
  let mut left = 0
  let mut right = bracket_code_points.length() - 1

  while left <= right {
    let mid = (left + right) / 2
    let mid_cp = bracket_code_points[mid]

    if cp < mid_cp {
      right = mid - 1
    } else if cp > mid_cp {
      left = mid + 1
    } else {
      return mid
    }
  }

  -1 // Not found
}

///|
/// Get the bracket type for a character
pub fn bracket_type(c : Char) -> BracketType {
  let idx = find_bracket_index(c)
  if idx < 0 {
    None
  } else if bracket_types[idx] == 0 {
    Open
  } else {
    Close
  }
}

///|
/// Get the paired bracket for a character
/// Returns None if the character is not a bracket
pub fn paired_bracket(c : Char) -> Char? {
  let idx = find_bracket_index(c)
  if idx < 0 {
    Option::None
  } else {
    Some(paired_brackets[idx].unsafe_to_char())
  }
}

///|
/// Check if a character is an opening bracket
pub fn is_open_bracket(c : Char) -> Bool {
  bracket_type(c) == Open
}

///|
/// Check if a character is a closing bracket
pub fn is_close_bracket(c : Char) -> Bool {
  bracket_type(c) == Close
}

///|
/// Check if two characters form a bracket pair (open, close)
pub fn is_bracket_pair(open : Char, close : Char) -> Bool {
  match paired_bracket(open) {
    Some(pair) => pair == close && bracket_type(open) == Open
    None => false
  }
}
'''

    output_path.write_text(code)
    print(f"Generated {output_path} with {len(code_points)} bracket pairs")


def main():
    # Determine paths
    script_dir = Path(__file__).parent
    project_root = script_dir.parent
    cache_dir = script_dir / ".cache"
    bidi_dir = project_root / "internal" / "bidi"

    cache_dir.mkdir(exist_ok=True)
    bidi_dir.mkdir(parents=True, exist_ok=True)

    # Download data files
    bidi_class_data = download_file(BIDI_CLASS_URL, cache_dir)
    mirroring_data = download_file(BIDI_MIRRORING_URL, cache_dir)
    brackets_data = download_file(BIDI_BRACKETS_URL, cache_dir)

    # Parse data
    print("Parsing DerivedBidiClass.txt...")
    bidi_class_entries = parse_bidi_class(bidi_class_data)
    print(f"  Found {len(bidi_class_entries)} Bidi class entries")

    print("Parsing BidiMirroring.txt...")
    mirroring_entries = parse_bidi_mirroring(mirroring_data)
    print(f"  Found {len(mirroring_entries)} mirroring entries")

    print("Parsing BidiBrackets.txt...")
    bracket_entries = parse_bidi_brackets(brackets_data)
    print(f"  Found {len(bracket_entries)} bracket entries")

    # Generate MoonBit files
    print("\nGenerating MoonBit source files...")

    generate_bidi_class_mbt(bidi_class_entries, bidi_dir / "bidi_class.mbt")
    generate_mirrored_mbt(mirroring_entries, bidi_dir / "mirrored.mbt")
    generate_bracket_mbt(bracket_entries, bidi_dir / "bracket.mbt")

    # Create moon.pkg.json
    pkg_json = bidi_dir / "moon.pkg.json"
    pkg_json.write_text("{}\n")
    print(f"Generated {pkg_json}")

    print("\nDone!")


if __name__ == "__main__":
    main()
