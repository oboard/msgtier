#!/usr/bin/env python3
"""
Generate MoonBit source files from Unicode Character Database files.

This script downloads and parses:
- UnicodeData.txt: CCC values, decomposition mappings, general category, case mappings
- CompositionExclusions.txt: Characters excluded from NFC composition

And generates:
- internal/ucd/ccc.mbt: Canonical Combining Class lookup
- internal/ucd/decomposition.mbt: Decomposition mappings
- internal/ucd/composition.mbt: Composition table and exclusions
- internal/ucd/general_category.mbt: General_Category lookup
- internal/ucd/case_mapping.mbt: Simple case mapping lookup
"""

import urllib.request
from pathlib import Path

# Unicode data URLs
UNICODE_VERSION = "16.0.0"
BASE_URL = f"https://www.unicode.org/Public/{UNICODE_VERSION}/ucd"
UNICODE_DATA_URL = f"{BASE_URL}/UnicodeData.txt"
COMPOSITION_EXCLUSIONS_URL = f"{BASE_URL}/CompositionExclusions.txt"
SPECIAL_CASING_URL = f"{BASE_URL}/SpecialCasing.txt"

# Hangul constants - handled algorithmically, not in tables
HANGUL_S_BASE = 0xAC00
HANGUL_S_COUNT = 11172


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


def parse_unicode_data(content: str) -> tuple[dict, dict, dict, set, dict, dict, dict, dict]:
    """
    Parse UnicodeData.txt and extract:
    - ccc_data: code_point -> canonical_combining_class
    - canonical_decomp: code_point -> [decomposed_cps]
    - compat_decomp: code_point -> [decomposed_cps]
    - mark_cps: set of code points with General_Category = Mark (Mn, Mc, Me)
    - gc_data: code_point -> general_category (string like "Lu", "Ll", etc.)
    - upper_mapping: code_point -> uppercase_code_point (only non-identity)
    - lower_mapping: code_point -> lowercase_code_point (only non-identity)
    - title_mapping: code_point -> titlecase_code_point (only non-identity)
    """
    ccc_data = {}
    canonical_decomp = {}
    compat_decomp = {}
    mark_cps = set()
    gc_data = {}
    upper_mapping = {}
    lower_mapping = {}
    title_mapping = {}

    for line in content.strip().split("\n"):
        if not line or line.startswith("#"):
            continue

        fields = line.split(";")
        if len(fields) < 15:
            continue

        cp = int(fields[0], 16)

        # Skip Hangul syllables - handled algorithmically
        if HANGUL_S_BASE <= cp < HANGUL_S_BASE + HANGUL_S_COUNT:
            continue

        # Field 2: General Category
        general_category = fields[2].strip()
        gc_data[cp] = general_category
        if general_category.startswith("M"):  # Mn, Mc, Me
            mark_cps.add(cp)

        # Field 3: Canonical Combining Class
        ccc = int(fields[3]) if fields[3] else 0
        if ccc != 0:
            ccc_data[cp] = ccc

        # Field 5: Decomposition mapping
        decomp = fields[5].strip()
        if decomp:
            # Check for compatibility decomposition tag
            if decomp.startswith("<"):
                # Compatibility decomposition: <tag> followed by code points
                parts = decomp.split(">", 1)
                if len(parts) > 1:
                    cps = [int(x, 16) for x in parts[1].strip().split()]
                    if cps:
                        compat_decomp[cp] = cps
            else:
                # Canonical decomposition: just code points
                cps = [int(x, 16) for x in decomp.split()]
                if cps:
                    canonical_decomp[cp] = cps

        # Field 12: Simple_Uppercase_Mapping
        upper = fields[12].strip()
        if upper:
            upper_cp = int(upper, 16)
            if upper_cp != cp:
                upper_mapping[cp] = upper_cp

        # Field 13: Simple_Lowercase_Mapping
        lower = fields[13].strip()
        if lower:
            lower_cp = int(lower, 16)
            if lower_cp != cp:
                lower_mapping[cp] = lower_cp

        # Field 14: Simple_Titlecase_Mapping
        title = fields[14].strip()
        if title:
            title_cp = int(title, 16)
            if title_cp != cp:
                title_mapping[cp] = title_cp

    return ccc_data, canonical_decomp, compat_decomp, mark_cps, gc_data, upper_mapping, lower_mapping, title_mapping


def parse_composition_exclusions(content: str) -> set[int]:
    """Parse CompositionExclusions.txt and return set of excluded code points."""
    exclusions = set()

    for line in content.strip().split("\n"):
        line = line.split("#")[0].strip()
        if not line:
            continue

        # Handle ranges (though this file typically has single code points)
        if ".." in line:
            start, end = line.split("..")
            for cp in range(int(start, 16), int(end, 16) + 1):
                exclusions.add(cp)
        else:
            exclusions.add(int(line, 16))

    return exclusions


def parse_special_casing(content: str) -> tuple[dict, dict, dict]:
    """
    Parse SpecialCasing.txt and extract unconditional mappings only.
    Returns: (lower_mapping, title_mapping, upper_mapping)
    Each dict: code_point -> [list of target code points]
    Skip entries with conditions in field 4 (like Final_Sigma, lt, tr, az).
    """
    lower_mapping = {}
    title_mapping = {}
    upper_mapping = {}

    for line in content.strip().split("\n"):
        # Remove comments
        line = line.split("#")[0].strip()
        if not line:
            continue

        fields = line.split(";")
        if len(fields) < 4:
            continue

        # Field 4 (index 4) contains conditions - skip if present
        # Format: <code>; <lower>; <title>; <upper>; (<condition_list>;)?
        if len(fields) > 4 and fields[4].strip():
            # Has condition, skip
            continue

        cp = int(fields[0].strip(), 16)
        lower_cps = [int(x, 16) for x in fields[1].strip().split() if x]
        title_cps = [int(x, 16) for x in fields[2].strip().split() if x]
        upper_cps = [int(x, 16) for x in fields[3].strip().split() if x]

        # Only store if different from identity (multi-char or different char)
        if lower_cps and (len(lower_cps) > 1 or lower_cps[0] != cp):
            lower_mapping[cp] = lower_cps
        if title_cps and (len(title_cps) > 1 or title_cps[0] != cp):
            title_mapping[cp] = title_cps
        if upper_cps and (len(upper_cps) > 1 or upper_cps[0] != cp):
            upper_mapping[cp] = upper_cps

    return lower_mapping, title_mapping, upper_mapping


def build_composition_table(canonical_decomp: dict, exclusions: set) -> dict:
    """
    Build composition table from decompositions.
    A pair (first, second) composes to cp if:
    - cp has canonical decomposition [first, second]
    - cp is not in composition exclusions
    - first is a starter (CCC=0) - implicitly true for first chars in decomp
    """
    composition = {}

    for cp, decomp in canonical_decomp.items():
        if len(decomp) != 2:
            continue
        if cp in exclusions:
            continue

        first, second = decomp
        composition[(first, second)] = cp

    return composition


def compress_ccc_ranges(ccc_data: dict) -> list[tuple[int, int, int]]:
    """
    Compress CCC data into ranges of (start, end, ccc) where consecutive
    code points have the same CCC value.
    """
    if not ccc_data:
        return []

    sorted_cps = sorted(ccc_data.keys())
    ranges = []

    start = sorted_cps[0]
    prev_cp = start
    prev_ccc = ccc_data[start]

    for cp in sorted_cps[1:]:
        ccc = ccc_data[cp]
        if cp == prev_cp + 1 and ccc == prev_ccc:
            prev_cp = cp
        else:
            ranges.append((start, prev_cp, prev_ccc))
            start = cp
            prev_cp = cp
            prev_ccc = ccc

    ranges.append((start, prev_cp, prev_ccc))
    return ranges


def compress_mark_ranges(mark_cps: set) -> list[tuple[int, int]]:
    """
    Compress mark code points into ranges of (start, end) where consecutive
    code points are all marks.
    """
    if not mark_cps:
        return []

    sorted_cps = sorted(mark_cps)
    ranges = []

    start = sorted_cps[0]
    prev_cp = start

    for cp in sorted_cps[1:]:
        if cp == prev_cp + 1:
            prev_cp = cp
        else:
            ranges.append((start, prev_cp))
            start = cp
            prev_cp = cp

    ranges.append((start, prev_cp))
    return ranges


def generate_ccc_mbt(ccc_ranges: list[tuple[int, int, int]], mark_ranges: list[tuple[int, int]], output_path: Path):
    """Generate ccc.mbt with CCC lookup data and mark detection."""

    # Store as arrays of (start, end, ccc) tuples
    # Use Int arrays for efficient lookup
    starts = []
    ends = []
    values = []

    for start, end, ccc in ccc_ranges:
        starts.append(start)
        ends.append(end)
        values.append(ccc)

    # Store mark ranges
    mark_starts = []
    mark_ends = []
    for start, end in mark_ranges:
        mark_starts.append(start)
        mark_ends.append(end)

    code = '''///|
/// Canonical Combining Class (CCC) lookup data
/// Generated from UnicodeData.txt

///|
/// CCC range start code points
let ccc_starts : FixedArray[Int] = [
'''

    # Write starts array
    for i, s in enumerate(starts):
        if i > 0:
            code += ",\n"
        code += f"  0x{s:04X}"
    code += "\n]\n\n"

    code += '''///|
/// CCC range end code points (inclusive)
let ccc_ends : FixedArray[Int] = [
'''
    for i, e in enumerate(ends):
        if i > 0:
            code += ",\n"
        code += f"  0x{e:04X}"
    code += "\n]\n\n"

    code += '''///|
/// CCC values for each range
let ccc_values : FixedArray[Int] = [
'''
    for i, v in enumerate(values):
        if i > 0:
            code += ",\n"
        code += f"  {v}"
    code += "\n]\n\n"

    # Add mark ranges
    code += '''///|
/// Mark character range start code points (General_Category = M)
let mark_starts : FixedArray[Int] = [
'''
    for i, s in enumerate(mark_starts):
        if i > 0:
            code += ",\n"
        code += f"  0x{s:04X}"
    code += "\n]\n\n"

    code += '''///|
/// Mark character range end code points (inclusive)
let mark_ends : FixedArray[Int] = [
'''
    for i, e in enumerate(mark_ends):
        if i > 0:
            code += ",\n"
        code += f"  0x{e:04X}"
    code += "\n]\n\n"

    code += '''///|
/// Look up Canonical Combining Class for a character
/// Returns 0 (starter) for most characters
pub fn lookup_ccc(c : Char) -> Int {
  let cp = c.to_int()
  // Binary search through ranges
  let mut left = 0
  let mut right = ccc_starts.length() - 1

  while left <= right {
    let mid = (left + right) / 2
    let start = ccc_starts[mid]
    let end = ccc_ends[mid]

    if cp < start {
      right = mid - 1
    } else if cp > end {
      left = mid + 1
    } else {
      return ccc_values[mid]
    }
  }

  0 // Not found, default CCC is 0 (starter)
}

///|
/// Check if a character is a Mark character (General_Category = Mn, Mc, or Me)
/// This is used for the IDNA "no leading combining mark" validation (V5/V6)
pub fn is_mark(c : Char) -> Bool {
  let cp = c.to_int()
  // Binary search through mark ranges
  let mut left = 0
  let mut right = mark_starts.length() - 1

  while left <= right {
    let mid = (left + right) / 2
    let start = mark_starts[mid]
    let end = mark_ends[mid]

    if cp < start {
      right = mid - 1
    } else if cp > end {
      left = mid + 1
    } else {
      return true
    }
  }

  false
}
'''

    output_path.write_text(code)
    print(f"Generated {output_path} with {len(ccc_ranges)} CCC ranges and {len(mark_ranges)} mark ranges")


def generate_decomposition_mbt(
    canonical_decomp: dict,
    compat_decomp: dict,
    output_path: Path
):
    """Generate decomposition.mbt with decomposition lookup data."""

    # Merge canonical and compat for unified storage
    # Store flag to distinguish them
    all_decomp = {}
    for cp, decomp in canonical_decomp.items():
        all_decomp[cp] = (decomp, False)  # False = canonical
    for cp, decomp in compat_decomp.items():
        if cp in all_decomp:
            # Already has canonical, add compat
            all_decomp[cp] = (all_decomp[cp][0], decomp)
        else:
            all_decomp[cp] = (None, decomp)  # None = no canonical, just compat

    # Sort by code point for binary search
    sorted_cps = sorted(all_decomp.keys())

    # Build index and data arrays
    # Index: [cp, data_start, canonical_len, compat_len]
    # Data: flattened decomposition code points

    index_cps = []
    index_data_starts = []
    index_canonical_lens = []
    index_compat_lens = []
    data = []

    for cp in sorted_cps:
        canonical, compat = all_decomp[cp]

        index_cps.append(cp)
        index_data_starts.append(len(data))

        if canonical:
            index_canonical_lens.append(len(canonical))
            data.extend(canonical)
        else:
            index_canonical_lens.append(0)

        if isinstance(compat, list):
            index_compat_lens.append(len(compat))
            data.extend(compat)
        else:
            index_compat_lens.append(0)

    code = '''///|
/// Decomposition mapping data
/// Generated from UnicodeData.txt

///|
/// Code points with decomposition mappings (sorted for binary search)
let decomp_cps : FixedArray[Int] = [
'''
    for i, cp in enumerate(index_cps):
        if i > 0:
            code += ",\n"
        code += f"  0x{cp:04X}"
    code += "\n]\n\n"

    code += '''///|
/// Data start index for each code point
let decomp_data_starts : FixedArray[Int] = [
'''
    for i, s in enumerate(index_data_starts):
        if i > 0:
            code += ",\n"
        code += f"  {s}"
    code += "\n]\n\n"

    code += '''///|
/// Canonical decomposition length (0 if none)
let decomp_canonical_lens : FixedArray[Int] = [
'''
    for i, l in enumerate(index_canonical_lens):
        if i > 0:
            code += ",\n"
        code += f"  {l}"
    code += "\n]\n\n"

    code += '''///|
/// Compatibility decomposition length (0 if none)
let decomp_compat_lens : FixedArray[Int] = [
'''
    for i, l in enumerate(index_compat_lens):
        if i > 0:
            code += ",\n"
        code += f"  {l}"
    code += "\n]\n\n"

    code += '''///|
/// Decomposition data (flattened code points)
let decomp_data : FixedArray[Int] = [
'''
    for i, d in enumerate(data):
        if i > 0:
            code += ",\n"
        code += f"  0x{d:04X}"
    code += "\n]\n\n"

    code += '''///|
/// Binary search for character index, returns -1 if not found
fn find_decomp_index(c : Char) -> Int {
  let cp = c.to_int()
  let mut left = 0
  let mut right = decomp_cps.length() - 1

  while left <= right {
    let mid = (left + right) / 2
    let mid_cp = decomp_cps[mid]

    if cp < mid_cp {
      right = mid - 1
    } else if cp > mid_cp {
      left = mid + 1
    } else {
      return mid
    }
  }

  -1
}

///|
/// Get canonical decomposition for a character
/// Returns None if no decomposition exists
pub fn get_canonical_decomposition(c : Char) -> Array[Char]? {
  let idx = find_decomp_index(c)
  if idx < 0 {
    return None
  }

  let len = decomp_canonical_lens[idx]
  if len == 0 {
    return None
  }

  let start = decomp_data_starts[idx]
  let result : Array[Char] = []
  for i = 0; i < len; i = i + 1 {
    result.push(decomp_data[start + i].unsafe_to_char())
  }
  Some(result)
}

///|
/// Get compatibility decomposition for a character
/// Returns None if no decomposition exists
pub fn get_compat_decomposition(c : Char) -> Array[Char]? {
  let idx = find_decomp_index(c)
  if idx < 0 {
    return None
  }

  let compat_len = decomp_compat_lens[idx]
  if compat_len == 0 {
    return None
  }

  // Compat data comes after canonical data
  let canonical_len = decomp_canonical_lens[idx]
  let start = decomp_data_starts[idx] + canonical_len
  let result : Array[Char] = []
  for i = 0; i < compat_len; i = i + 1 {
    result.push(decomp_data[start + i].unsafe_to_char())
  }
  Some(result)
}
'''

    output_path.write_text(code)
    print(f"Generated {output_path} with {len(sorted_cps)} decompositions, {len(data)} data points")


def generate_composition_mbt(
    composition: dict,
    exclusions: set,
    ccc_data: dict,
    canonical_decomp: dict,
    output_path: Path
):
    """Generate composition.mbt with composition lookup data."""

    # For composition, we need to be able to look up: (starter, combining) -> composed
    # Store as parallel arrays sorted by (first, second) for binary search

    sorted_pairs = sorted(composition.keys())

    firsts = []
    seconds = []
    results = []

    for first, second in sorted_pairs:
        firsts.append(first)
        seconds.append(second)
        results.append(composition[(first, second)])

    # Build full exclusion list including:
    # 1. Explicit exclusions from CompositionExclusions.txt
    # 2. Singletons (decomposition to single character)
    # 3. Non-starter decompositions (first char has CCC > 0)
    full_exclusions = set(exclusions)

    for cp, decomp in canonical_decomp.items():
        # Singleton exclusion
        if len(decomp) == 1:
            full_exclusions.add(cp)
        # Non-starter decomposition
        elif len(decomp) > 0 and ccc_data.get(decomp[0], 0) > 0:
            full_exclusions.add(cp)

    sorted_exclusions = sorted(full_exclusions)

    code = '''///|
/// Composition lookup data
/// Generated from UnicodeData.txt and CompositionExclusions.txt

///|
/// First code points of composition pairs (sorted)
let comp_firsts : FixedArray[Int] = [
'''
    for i, f in enumerate(firsts):
        if i > 0:
            code += ",\n"
        code += f"  0x{f:04X}"
    code += "\n]\n\n"

    code += '''///|
/// Second code points of composition pairs
let comp_seconds : FixedArray[Int] = [
'''
    for i, s in enumerate(seconds):
        if i > 0:
            code += ",\n"
        code += f"  0x{s:04X}"
    code += "\n]\n\n"

    code += '''///|
/// Composed result code points
let comp_results : FixedArray[Int] = [
'''
    for i, r in enumerate(results):
        if i > 0:
            code += ",\n"
        code += f"  0x{r:04X}"
    code += "\n]\n\n"

    code += '''///|
/// Composition exclusions (sorted for binary search)
let comp_exclusions : FixedArray[Int] = [
'''
    for i, e in enumerate(sorted_exclusions):
        if i > 0:
            code += ",\n"
        code += f"  0x{e:04X}"
    code += "\n]\n\n"

    code += '''///|
/// Look up composition for a pair of characters
/// Returns Some(composed) if composition exists, None otherwise
pub fn lookup_composition(starter : Char, combining : Char) -> Char? {
  let starter_cp = starter.to_int()
  let combining_cp = combining.to_int()
  // Binary search for the pair
  let mut left = 0
  let mut right = comp_firsts.length() - 1

  while left <= right {
    let mid = (left + right) / 2
    let mid_first = comp_firsts[mid]
    let mid_second = comp_seconds[mid]

    if starter_cp < mid_first || (starter_cp == mid_first && combining_cp < mid_second) {
      right = mid - 1
    } else if starter_cp > mid_first || (starter_cp == mid_first && combining_cp > mid_second) {
      left = mid + 1
    } else {
      return Some(comp_results[mid].unsafe_to_char())
    }
  }

  None
}

///|
/// Check if a character is excluded from composition
pub fn is_composition_excluded(c : Char) -> Bool {
  let cp = c.to_int()
  // Binary search in exclusions
  let mut left = 0
  let mut right = comp_exclusions.length() - 1

  while left <= right {
    let mid = (left + right) / 2
    let mid_cp = comp_exclusions[mid]

    if cp < mid_cp {
      right = mid - 1
    } else if cp > mid_cp {
      left = mid + 1
    } else {
      return true
    }
  }

  false
}
'''

    output_path.write_text(code)
    print(f"Generated {output_path} with {len(sorted_pairs)} compositions, {len(sorted_exclusions)} exclusions")


# General Category enum mapping (order matches MoonBit enum ordinal)
GC_ENUM_ORDER = [
    "Lu", "Ll", "Lt", "Lm", "Lo",  # Letter (0-4)
    "Mn", "Mc", "Me",              # Mark (5-7)
    "Nd", "Nl", "No",              # Number (8-10)
    "Zs", "Zl", "Zp",              # Separator (11-13)
    "Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po",  # Punctuation (14-20)
    "Sm", "Sc", "Sk", "So",        # Symbol (21-24)
    "Cc", "Cf", "Cs", "Co", "Cn",  # Other (25-29)
]
GC_TO_ORDINAL = {gc: i for i, gc in enumerate(GC_ENUM_ORDER)}


def compress_gc_ranges(gc_data: dict) -> list[tuple[int, int, int]]:
    """
    Compress General_Category data into ranges of (start, end, gc_ordinal)
    where consecutive code points have the same category.
    """
    if not gc_data:
        return []

    # Fill in gaps with "Cn" (unassigned) up to max code point
    sorted_cps = sorted(gc_data.keys())
    max_cp = max(sorted_cps)

    # Build ranges with category ordinals
    ranges = []
    prev_cp = -2
    prev_gc_ord = -1
    start = 0

    for cp in range(max_cp + 1):
        gc = gc_data.get(cp, "Cn")
        gc_ord = GC_TO_ORDINAL.get(gc, GC_TO_ORDINAL["Cn"])

        if cp == prev_cp + 1 and gc_ord == prev_gc_ord:
            # Continue current range
            prev_cp = cp
        else:
            # Save previous range if valid
            if prev_gc_ord >= 0:
                ranges.append((start, prev_cp, prev_gc_ord))
            # Start new range
            start = cp
            prev_cp = cp
            prev_gc_ord = gc_ord

    # Don't forget the last range
    if prev_gc_ord >= 0:
        ranges.append((start, prev_cp, prev_gc_ord))

    return ranges


def generate_general_category_mbt(gc_ranges: list[tuple[int, int, int]], output_path: Path):
    """Generate general_category.mbt with General_Category lookup data."""

    starts = []
    ends = []
    values = []

    for start, end, gc_ord in gc_ranges:
        starts.append(start)
        ends.append(end)
        values.append(gc_ord)

    code = '''///|
/// General_Category lookup data
/// Generated from UnicodeData.txt

///|
/// General_Category range start code points
let gc_range_starts : FixedArray[Int] = [
'''

    for i, s in enumerate(starts):
        if i > 0:
            code += ",\n"
        code += f"  0x{s:04X}"
    code += "\n]\n\n"

    code += '''///|
/// General_Category range end code points (inclusive)
let gc_range_ends : FixedArray[Int] = [
'''
    for i, e in enumerate(ends):
        if i > 0:
            code += ",\n"
        code += f"  0x{e:04X}"
    code += "\n]\n\n"

    code += '''///|
/// General_Category values for each range (enum ordinal)
let gc_values : FixedArray[Int] = [
'''
    for i, v in enumerate(values):
        if i > 0:
            code += ",\n"
        code += f"  {v}"
    code += "\n]\n\n"

    code += '''///|
/// Look up General_Category ordinal for a character
/// Returns ordinal value (0-29) corresponding to GeneralCategory enum
/// Default is 29 (Cn = Unassigned) for characters beyond data range
pub fn lookup_general_category(c : Char) -> Int {
  let cp = c.to_int()
  // Handle code points beyond our data range
  if cp < 0 || cp > gc_range_ends[gc_range_ends.length() - 1] {
    return 29 // Cn (Unassigned)
  }

  // Binary search through ranges
  let mut left = 0
  let mut right = gc_range_starts.length() - 1

  while left <= right {
    let mid = (left + right) / 2
    let start = gc_range_starts[mid]
    let end = gc_range_ends[mid]

    if cp < start {
      right = mid - 1
    } else if cp > end {
      left = mid + 1
    } else {
      return gc_values[mid]
    }
  }

  29 // Cn (Unassigned)
}
'''

    output_path.write_text(code)
    print(f"Generated {output_path} with {len(gc_ranges)} General_Category ranges")


def generate_case_mapping_mbt(
    simple_upper: dict,
    simple_lower: dict,
    simple_title: dict,
    full_upper: dict,
    full_lower: dict,
    full_title: dict,
    output_path: Path
):
    """Generate case_mapping.mbt with simple and full case mapping lookup data."""

    # Sort simple mappings by code point for binary search
    upper_cps = sorted(simple_upper.keys())
    lower_cps = sorted(simple_lower.keys())
    title_cps = sorted(simple_title.keys())

    code = '''///|
/// Simple case mapping lookup data
/// Generated from UnicodeData.txt

///|
/// Code points with uppercase mappings (sorted for binary search)
let upper_cps : FixedArray[Int] = [
'''
    for i, cp in enumerate(upper_cps):
        if i > 0:
            code += ",\n"
        code += f"  0x{cp:04X}"
    code += "\n]\n\n"

    code += '''///|
/// Uppercase mapping targets
let upper_targets : FixedArray[Int] = [
'''
    for i, cp in enumerate(upper_cps):
        if i > 0:
            code += ",\n"
        code += f"  0x{simple_upper[cp]:04X}"
    code += "\n]\n\n"

    code += '''///|
/// Code points with lowercase mappings (sorted for binary search)
let lower_cps : FixedArray[Int] = [
'''
    for i, cp in enumerate(lower_cps):
        if i > 0:
            code += ",\n"
        code += f"  0x{cp:04X}"
    code += "\n]\n\n"

    code += '''///|
/// Lowercase mapping targets
let lower_targets : FixedArray[Int] = [
'''
    for i, cp in enumerate(lower_cps):
        if i > 0:
            code += ",\n"
        code += f"  0x{simple_lower[cp]:04X}"
    code += "\n]\n\n"

    code += '''///|
/// Code points with titlecase mappings (sorted for binary search)
let title_cps : FixedArray[Int] = [
'''
    for i, cp in enumerate(title_cps):
        if i > 0:
            code += ",\n"
        code += f"  0x{cp:04X}"
    code += "\n]\n\n"

    code += '''///|
/// Titlecase mapping targets
let title_targets : FixedArray[Int] = [
'''
    for i, cp in enumerate(title_cps):
        if i > 0:
            code += ",\n"
        code += f"  0x{simple_title[cp]:04X}"
    code += "\n]\n\n"

    code += '''///|
/// Binary search helper - returns index if found, -1 otherwise
fn binary_search_case(arr : FixedArray[Int], cp : Int) -> Int {
  let mut left = 0
  let mut right = arr.length() - 1

  while left <= right {
    let mid = (left + right) / 2
    let mid_cp = arr[mid]

    if cp < mid_cp {
      right = mid - 1
    } else if cp > mid_cp {
      left = mid + 1
    } else {
      return mid
    }
  }

  -1
}

///|
/// Look up simple uppercase mapping for a character
/// Returns the character itself if no mapping exists
pub fn lookup_simple_uppercase(c : Char) -> Char {
  let cp = c.to_int()
  let idx = binary_search_case(upper_cps, cp)
  if idx >= 0 {
    upper_targets[idx].unsafe_to_char()
  } else {
    c
  }
}

///|
/// Look up simple lowercase mapping for a character
/// Returns the character itself if no mapping exists
pub fn lookup_simple_lowercase(c : Char) -> Char {
  let cp = c.to_int()
  let idx = binary_search_case(lower_cps, cp)
  if idx >= 0 {
    lower_targets[idx].unsafe_to_char()
  } else {
    c
  }
}

///|
/// Look up simple titlecase mapping for a character
/// Returns the character itself if no mapping exists
pub fn lookup_simple_titlecase(c : Char) -> Char {
  let cp = c.to_int()
  let idx = binary_search_case(title_cps, cp)
  if idx >= 0 {
    title_targets[idx].unsafe_to_char()
  } else {
    c
  }
}
'''

    # Generate full case mapping data
    # Merge simple mappings with special multi-character mappings
    def build_full_mapping(simple: dict, special: dict) -> dict:
        """Build full mapping table: simple 1:1 as single-element lists, override with special."""
        full = {}
        for cp, target in simple.items():
            full[cp] = [target]
        for cp, targets in special.items():
            full[cp] = targets
        return full

    merged_upper = build_full_mapping(simple_upper, full_upper)
    merged_lower = build_full_mapping(simple_lower, full_lower)
    merged_title = build_full_mapping(simple_title, full_title)

    # Generate full case mapping arrays
    def generate_full_case_arrays(mapping: dict, name: str) -> tuple[str, int, int]:
        """Generate arrays for full case mapping using decomposition pattern."""
        sorted_cps = sorted(mapping.keys())

        cps_arr = []
        data_starts = []
        lens = []
        data = []

        for cp in sorted_cps:
            targets = mapping[cp]
            cps_arr.append(cp)
            data_starts.append(len(data))
            lens.append(len(targets))
            data.extend(targets)

        result = f'''
///|
/// Code points with full {name} mappings (sorted for binary search)
let full_{name}_cps : FixedArray[Int] = [
'''
        for i, cp in enumerate(cps_arr):
            if i > 0:
                result += ",\n"
            result += f"  0x{cp:04X}"
        result += "\n]\n\n"

        result += f'''///|
/// Data start index for each full {name} mapping
let full_{name}_data_starts : FixedArray[Int] = [
'''
        for i, s in enumerate(data_starts):
            if i > 0:
                result += ",\n"
            result += f"  {s}"
        result += "\n]\n\n"

        result += f'''///|
/// Length of each full {name} mapping
let full_{name}_lens : FixedArray[Int] = [
'''
        for i, l in enumerate(lens):
            if i > 0:
                result += ",\n"
            result += f"  {l}"
        result += "\n]\n\n"

        result += f'''///|
/// Flattened full {name} mapping target code points
let full_{name}_data : FixedArray[Int] = [
'''
        for i, d in enumerate(data):
            if i > 0:
                result += ",\n"
            result += f"  0x{d:04X}"
        result += "\n]\n"

        return result, len(cps_arr), len(data)

    upper_code, upper_count, upper_data_count = generate_full_case_arrays(merged_upper, "upper")
    lower_code, lower_count, lower_data_count = generate_full_case_arrays(merged_lower, "lower")
    title_code, title_count, title_data_count = generate_full_case_arrays(merged_title, "title")

    code += upper_code
    code += lower_code
    code += title_code

    # Add lookup functions for full case mappings
    code += '''
///|
/// Look up full uppercase mapping for a character
/// Returns Some(array of chars) if a mapping exists, None otherwise
pub fn lookup_full_uppercase(c : Char) -> Array[Char]? {
  let cp = c.to_int()
  let idx = binary_search_case(full_upper_cps, cp)
  if idx < 0 {
    return None
  }
  let start = full_upper_data_starts[idx]
  let len = full_upper_lens[idx]
  let result : Array[Char] = []
  for i = 0; i < len; i = i + 1 {
    result.push(full_upper_data[start + i].unsafe_to_char())
  }
  Some(result)
}

///|
/// Look up full lowercase mapping for a character
/// Returns Some(array of chars) if a mapping exists, None otherwise
pub fn lookup_full_lowercase(c : Char) -> Array[Char]? {
  let cp = c.to_int()
  let idx = binary_search_case(full_lower_cps, cp)
  if idx < 0 {
    return None
  }
  let start = full_lower_data_starts[idx]
  let len = full_lower_lens[idx]
  let result : Array[Char] = []
  for i = 0; i < len; i = i + 1 {
    result.push(full_lower_data[start + i].unsafe_to_char())
  }
  Some(result)
}

///|
/// Look up full titlecase mapping for a character
/// Returns Some(array of chars) if a mapping exists, None otherwise
pub fn lookup_full_titlecase(c : Char) -> Array[Char]? {
  let cp = c.to_int()
  let idx = binary_search_case(full_title_cps, cp)
  if idx < 0 {
    return None
  }
  let start = full_title_data_starts[idx]
  let len = full_title_lens[idx]
  let result : Array[Char] = []
  for i = 0; i < len; i = i + 1 {
    result.push(full_title_data[start + i].unsafe_to_char())
  }
  Some(result)
}
'''

    output_path.write_text(code)
    print(f"Generated {output_path} with {len(upper_cps)} simple upper, {len(lower_cps)} simple lower, {len(title_cps)} simple title mappings")
    print(f"  Full case mappings: {upper_count} upper ({upper_data_count} data), {lower_count} lower ({lower_data_count} data), {title_count} title ({title_data_count} data)")


def main():
    # Determine paths
    script_dir = Path(__file__).parent
    project_root = script_dir.parent
    cache_dir = script_dir / ".cache"
    ucd_dir = project_root / "internal" / "ucd"

    cache_dir.mkdir(exist_ok=True)
    ucd_dir.mkdir(parents=True, exist_ok=True)

    # Download data files
    unicode_data = download_file(UNICODE_DATA_URL, cache_dir)
    exclusions_data = download_file(COMPOSITION_EXCLUSIONS_URL, cache_dir)
    special_casing_data = download_file(SPECIAL_CASING_URL, cache_dir)

    # Parse data
    print("Parsing UnicodeData.txt...")
    ccc_data, canonical_decomp, compat_decomp, mark_cps, gc_data, simple_upper, simple_lower, simple_title = parse_unicode_data(unicode_data)
    print(f"  Found {len(ccc_data)} non-zero CCC entries")
    print(f"  Found {len(canonical_decomp)} canonical decompositions")
    print(f"  Found {len(compat_decomp)} compatibility decompositions")
    print(f"  Found {len(mark_cps)} mark characters")
    print(f"  Found {len(gc_data)} General_Category entries")
    print(f"  Found {len(simple_upper)} simple uppercase mappings")
    print(f"  Found {len(simple_lower)} simple lowercase mappings")
    print(f"  Found {len(simple_title)} simple titlecase mappings")

    print("Parsing CompositionExclusions.txt...")
    exclusions = parse_composition_exclusions(exclusions_data)
    print(f"  Found {len(exclusions)} explicit exclusions")

    print("Parsing SpecialCasing.txt...")
    full_lower, full_title, full_upper = parse_special_casing(special_casing_data)
    print(f"  Found {len(full_upper)} full uppercase mappings")
    print(f"  Found {len(full_lower)} full lowercase mappings")
    print(f"  Found {len(full_title)} full titlecase mappings")

    print("Building composition table...")
    composition = build_composition_table(canonical_decomp, exclusions)
    print(f"  Found {len(composition)} composition pairs")

    # Generate MoonBit files
    print("\nGenerating MoonBit source files...")

    # CCC and mark data
    ccc_ranges = compress_ccc_ranges(ccc_data)
    mark_ranges = compress_mark_ranges(mark_cps)
    generate_ccc_mbt(ccc_ranges, mark_ranges, ucd_dir / "ccc.mbt")

    # Decomposition data
    generate_decomposition_mbt(canonical_decomp, compat_decomp, ucd_dir / "decomposition.mbt")

    # Composition data
    generate_composition_mbt(composition, exclusions, ccc_data, canonical_decomp, ucd_dir / "composition.mbt")

    # General_Category data
    gc_ranges = compress_gc_ranges(gc_data)
    generate_general_category_mbt(gc_ranges, ucd_dir / "general_category.mbt")

    # Case mapping data
    generate_case_mapping_mbt(
        simple_upper, simple_lower, simple_title,
        full_upper, full_lower, full_title,
        ucd_dir / "case_mapping.mbt"
    )

    # Remove the stub file if it exists
    stub_file = ucd_dir / "ucd.mbt"
    if stub_file.exists():
        stub_file.unlink()
        print(f"Removed stub file {stub_file}")

    print("\nDone!")


if __name__ == "__main__":
    main()
