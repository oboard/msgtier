#!/usr/bin/env python3
"""
Generate MoonBit source files for IDNA (UTS #46) from Unicode data files.

This script downloads and parses:
- IdnaMappingTable.txt: IDNA status and mappings
- DerivedJoiningType.txt: Joining_Type property (for ContextJ)

And generates:
- internal/idna/mapping.mbt: IDNA mapping table lookup
- internal/idna/joining.mbt: Joining_Type lookup

Note: Bidi_Class lookup is now provided by the bidi package.
"""

import urllib.request
from pathlib import Path

# Unicode data URLs
UNICODE_VERSION = "16.0.0"
IDNA_URL = f"https://www.unicode.org/Public/idna/{UNICODE_VERSION}/IdnaMappingTable.txt"
JOINING_URL = f"https://www.unicode.org/Public/{UNICODE_VERSION}/ucd/extracted/DerivedJoiningType.txt"


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


def parse_idna_mapping_table(content: str) -> list[tuple]:
    """
    Parse IdnaMappingTable.txt.
    Returns list of (start, end, status, mapping).
    Status: valid, ignored, mapped, deviation, disallowed, disallowed_STD3_valid, disallowed_STD3_mapped
    Mapping: list of code points or empty list
    """
    entries = []

    for line in content.strip().split("\n"):
        # Remove comments
        if "#" in line:
            line = line.split("#")[0]
        line = line.strip()
        if not line:
            continue

        parts = [p.strip() for p in line.split(";")]
        if len(parts) < 2:
            continue

        start, end = parse_range(parts[0])
        status = parts[1].lower().replace(" ", "_")

        # Parse mapping if present
        mapping = []
        if len(parts) > 2 and parts[2]:
            mapping = [int(cp, 16) for cp in parts[2].split()]

        entries.append((start, end, status, mapping))

    return entries


def parse_joining_type(content: str) -> list[tuple]:
    """
    Parse DerivedJoiningType.txt.
    Returns list of (start, end, joining_type).
    We need: L, R, D, C, T for ContextJ rules.
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
        joining_type = parts[1].strip()

        entries.append((start, end, joining_type))

    return entries


def generate_mapping_mbt(entries: list[tuple], output_path: Path):
    """Generate mapping.mbt with IDNA mapping table."""

    # Build compact representation
    # Separate entries into: ranges without mapping (status only) and with mapping

    # For ranges: (start, end, status_code)
    # Status codes: 0=valid, 1=ignored, 2=mapped, 3=deviation, 4=disallowed, 5=disallowed_STD3_valid, 6=disallowed_STD3_mapped
    status_map = {
        "valid": 0,
        "ignored": 1,
        "mapped": 2,
        "deviation": 3,
        "disallowed": 4,
        "disallowed_std3_valid": 5,
        "disallowed_std3_mapped": 6,
    }

    range_starts = []
    range_ends = []
    range_statuses = []
    mapping_starts = []  # Index into mapping_data
    mapping_lens = []
    mapping_data = []

    for start, end, status, mapping in entries:
        status_code = status_map.get(status, 4)  # Default to disallowed
        range_starts.append(start)
        range_ends.append(end)
        range_statuses.append(status_code)
        mapping_starts.append(len(mapping_data))
        mapping_lens.append(len(mapping))
        mapping_data.extend(mapping)

    code = '''///|
/// IDNA Mapping Table (UTS #46)
/// Generated from IdnaMappingTable.txt

///|
/// IDNA status values
pub(all) enum IdnaStatus {
  Valid             // 0: Valid character
  Ignored           // 1: Character is removed
  Mapped            // 2: Character is mapped to other characters
  Deviation         // 3: Treated as valid in nontransitional mode
  Disallowed        // 4: Character is not allowed
  DisallowedSTD3Valid  // 5: Valid only without UseSTD3ASCIIRules
  DisallowedSTD3Mapped // 6: Mapped only without UseSTD3ASCIIRules
} derive(Show, Eq)

///|
/// Range start code points
let idna_range_starts : FixedArray[Int] = [
'''
    for i, s in enumerate(range_starts):
        if i > 0:
            code += ",\n"
        code += f"  0x{s:04X}"
    code += "\n]\n\n"

    code += '''///|
/// Range end code points (inclusive)
let idna_range_ends : FixedArray[Int] = [
'''
    for i, e in enumerate(range_ends):
        if i > 0:
            code += ",\n"
        code += f"  0x{e:04X}"
    code += "\n]\n\n"

    code += '''///|
/// Status codes for each range
let idna_range_statuses : FixedArray[Int] = [
'''
    for i, s in enumerate(range_statuses):
        if i > 0:
            code += ",\n"
        code += f"  {s}"
    code += "\n]\n\n"

    code += '''///|
/// Mapping data start indices
let idna_mapping_starts : FixedArray[Int] = [
'''
    for i, s in enumerate(mapping_starts):
        if i > 0:
            code += ",\n"
        code += f"  {s}"
    code += "\n]\n\n"

    code += '''///|
/// Mapping data lengths
let idna_mapping_lens : FixedArray[Int] = [
'''
    for i, l in enumerate(mapping_lens):
        if i > 0:
            code += ",\n"
        code += f"  {l}"
    code += "\n]\n\n"

    code += '''///|
/// Mapping data (flattened code points)
let idna_mapping_data : FixedArray[Int] = [
'''
    for i, d in enumerate(mapping_data):
        if i > 0:
            code += ",\n"
        code += f"  0x{d:04X}"
    if not mapping_data:
        code += "  0"  # Empty array placeholder
    code += "\n]\n\n"

    code += '''///|
/// Binary search for character in IDNA ranges
fn find_idna_range(c : Char) -> Int {
  let cp = c.to_int()
  let mut left = 0
  let mut right = idna_range_starts.length() - 1

  while left <= right {
    let mid = (left + right) / 2
    let start = idna_range_starts[mid]
    let end = idna_range_ends[mid]

    if cp < start {
      right = mid - 1
    } else if cp > end {
      left = mid + 1
    } else {
      return mid
    }
  }

  -1 // Not found, should not happen for valid Unicode
}

///|
/// Convert status code to IdnaStatus enum
fn status_from_code(code : Int) -> IdnaStatus {
  match code {
    0 => Valid
    1 => Ignored
    2 => Mapped
    3 => Deviation
    4 => Disallowed
    5 => DisallowedSTD3Valid
    6 => DisallowedSTD3Mapped
    _ => Disallowed
  }
}

///|
/// Look up IDNA status and mapping for a character
/// Returns (status, mapping) where mapping is empty array if no mapping
pub fn lookup_idna_mapping(c : Char) -> (IdnaStatus, Array[Char]) {
  let idx = find_idna_range(c)
  if idx < 0 {
    // Not found, treat as disallowed
    return (Disallowed, [])
  }

  let status = status_from_code(idna_range_statuses[idx])
  let mapping_start = idna_mapping_starts[idx]
  let mapping_len = idna_mapping_lens[idx]

  let mapping : Array[Char] = []
  for i = 0; i < mapping_len; i = i + 1 {
    mapping.push(idna_mapping_data[mapping_start + i].unsafe_to_char())
  }

  (status, mapping)
}
'''

    output_path.write_text(code)
    print(f"Generated {output_path} with {len(range_starts)} ranges, {len(mapping_data)} mapping entries")


def generate_joining_mbt(entries: list[tuple], output_path: Path):
    """Generate joining.mbt with Joining_Type lookup."""

    # Joining types: L, R, D, C, T, U (non-joining)
    joining_map = {"L": 0, "R": 1, "D": 2, "C": 3, "T": 4, "U": 5}

    # Filter relevant entries and sort by start code point for binary search
    filtered_entries = [(start, end, joining_map[joining_type])
                        for start, end, joining_type in entries
                        if joining_type in joining_map]
    filtered_entries.sort(key=lambda x: x[0])  # Sort by start code point

    range_starts = [e[0] for e in filtered_entries]
    range_ends = [e[1] for e in filtered_entries]
    range_types = [e[2] for e in filtered_entries]

    code = '''///|
/// Joining_Type lookup for IDNA ContextJ validation (RFC 5892)
/// Generated from DerivedJoiningType.txt

///|
/// Joining type values
pub(all) enum JoiningType {
  LeftJoining       // L
  RightJoining      // R
  DualJoining       // D
  JoinCausing       // C
  Transparent       // T
  NonJoining        // U
} derive(Show, Eq)

///|
/// Range start code points
let joining_range_starts : FixedArray[Int] = [
'''
    for i, s in enumerate(range_starts):
        if i > 0:
            code += ",\n"
        code += f"  0x{s:04X}"
    code += "\n]\n\n"

    code += '''///|
/// Range end code points (inclusive)
let joining_range_ends : FixedArray[Int] = [
'''
    for i, e in enumerate(range_ends):
        if i > 0:
            code += ",\n"
        code += f"  0x{e:04X}"
    code += "\n]\n\n"

    code += '''///|
/// Joining type codes for each range
let joining_range_types : FixedArray[Int] = [
'''
    for i, t in enumerate(range_types):
        if i > 0:
            code += ",\n"
        code += f"  {t}"
    code += "\n]\n\n"

    code += '''///|
/// Binary search for character in joining ranges
fn find_joining_range(c : Char) -> Int {
  let cp = c.to_int()
  let mut left = 0
  let mut right = joining_range_starts.length() - 1

  while left <= right {
    let mid = (left + right) / 2
    let start = joining_range_starts[mid]
    let end = joining_range_ends[mid]

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
/// Convert type code to JoiningType enum
fn joining_from_code(code : Int) -> JoiningType {
  match code {
    0 => LeftJoining
    1 => RightJoining
    2 => DualJoining
    3 => JoinCausing
    4 => Transparent
    _ => NonJoining
  }
}

///|
/// Look up Joining_Type for a character
pub fn lookup_joining_type(c : Char) -> JoiningType {
  let idx = find_joining_range(c)
  if idx < 0 {
    return NonJoining
  }
  joining_from_code(joining_range_types[idx])
}
'''

    output_path.write_text(code)
    print(f"Generated {output_path} with {len(range_starts)} joining ranges")


def main():
    # Determine paths
    script_dir = Path(__file__).parent
    project_root = script_dir.parent
    cache_dir = script_dir / ".cache"
    idna_dir = project_root / "internal" / "idna"

    cache_dir.mkdir(exist_ok=True)
    idna_dir.mkdir(parents=True, exist_ok=True)

    # Download data files
    idna_data = download_file(IDNA_URL, cache_dir)
    joining_data = download_file(JOINING_URL, cache_dir)

    # Parse data
    print("Parsing IdnaMappingTable.txt...")
    idna_entries = parse_idna_mapping_table(idna_data)
    print(f"  Found {len(idna_entries)} IDNA mapping entries")

    print("Parsing DerivedJoiningType.txt...")
    joining_entries = parse_joining_type(joining_data)
    print(f"  Found {len(joining_entries)} joining type entries")

    # Generate MoonBit files
    print("\nGenerating MoonBit source files...")

    generate_mapping_mbt(idna_entries, idna_dir / "mapping.mbt")
    generate_joining_mbt(joining_entries, idna_dir / "joining.mbt")

    print("\nDone!")


if __name__ == "__main__":
    main()
