///|
pub fn emit_ccc(
  ccc_ranges : Array[CccRange],
  mark_ranges : Array[CodePointRange],
) -> String {
  let out = @emitter.Emitter::new()
  out.write_file_header(
    "Canonical Combining Class (CCC) lookup data", "UnicodeData.txt",
  )
  out.write_int_array(
    "CCC range start code points",
    "ccc_starts",
    ccc_ranges.map(range => range.start),
    hex=true,
  )
  out.write_int_array(
    "CCC range end code points (inclusive)",
    "ccc_ends",
    ccc_ranges.map(range => range.end),
    hex=true,
  )
  out.write_int_array(
    "CCC values for each range",
    "ccc_values",
    ccc_ranges.map(range => range.value),
    hex=false,
  )
  out.write_int_array(
    "Mark character range start code points (General_Category = M)",
    "mark_starts",
    mark_ranges.map(range => range.start),
    hex=true,
  )
  out.write_int_array(
    "Mark character range end code points (inclusive)",
    "mark_ends",
    mark_ranges.map(range => range.end),
    hex=true,
  )
  out.write(
    (
      #|///|
      #|/// Look up Canonical Combining Class for a character
      #|/// Returns 0 (starter) for most characters
      #|pub fn lookup_ccc(c : Char) -> Int {
      #|  let cp = c.to_int()
      #|  // Binary search through ranges
      #|  let mut left = 0
      #|  let mut right = ccc_starts.length() - 1
      #|
      #|  while left <= right {
      #|    let mid = (left + right) / 2
      #|    let start = ccc_starts[mid]
      #|    let end = ccc_ends[mid]
      #|
      #|    if cp < start {
      #|      right = mid - 1
      #|    } else if cp > end {
      #|      left = mid + 1
      #|    } else {
      #|      return ccc_values[mid]
      #|    }
      #|  }
      #|
      #|  0 // Not found, default CCC is 0 (starter)
      #|}
      #|
      #|///|
      #|/// Check if a character is a Mark character (General_Category = Mn, Mc, or Me)
      #|/// This is used for the IDNA "no leading combining mark" validation (V5/V6)
      #|pub fn is_mark(c : Char) -> Bool {
      #|  let cp = c.to_int()
      #|  // Binary search through mark ranges
      #|  let mut left = 0
      #|  let mut right = mark_starts.length() - 1
      #|
      #|  while left <= right {
      #|    let mid = (left + right) / 2
      #|    let start = mark_starts[mid]
      #|    let end = mark_ends[mid]
      #|
      #|    if cp < start {
      #|      right = mid - 1
      #|    } else if cp > end {
      #|      left = mid + 1
      #|    } else {
      #|      return true
      #|    }
      #|  }
      #|
      #|  false
      #|}
      #|
    ),
  )
  out.finish()
}

///|
pub fn emit_general_category(ranges : Array[GeneralCategoryRange]) -> String {
  let out = @emitter.Emitter::new()
  out.write_file_header("General_Category lookup data", "UnicodeData.txt")
  out.write_int_array(
    "General_Category range start code points",
    "gc_range_starts",
    ranges.map(range => range.start),
    hex=true,
  )
  out.write_int_array(
    "General_Category range end code points (inclusive)",
    "gc_range_ends",
    ranges.map(range => range.end),
    hex=true,
  )
  out.write_int_array(
    "General_Category values for each range (enum ordinal)",
    "gc_values",
    ranges.map(range => range.value),
    hex=false,
  )
  out.write(
    (
      #|///|
      #|/// Look up General_Category ordinal for a character
      #|/// Returns ordinal value (0-29) corresponding to GeneralCategory enum
      #|/// Default is 29 (Cn = Unassigned) for characters beyond data range
      #|pub fn lookup_general_category(c : Char) -> Int {
      #|  let cp = c.to_int()
      #|  // Handle code points beyond our data range
      #|  if cp < 0 || cp > gc_range_ends[gc_range_ends.length() - 1] {
      #|    return 29 // Cn (Unassigned)
      #|  }
      #|
      #|  // Binary search through ranges
      #|  let mut left = 0
      #|  let mut right = gc_range_starts.length() - 1
      #|
      #|  while left <= right {
      #|    let mid = (left + right) / 2
      #|    let start = gc_range_starts[mid]
      #|    let end = gc_range_ends[mid]
      #|
      #|    if cp < start {
      #|      right = mid - 1
      #|    } else if cp > end {
      #|      left = mid + 1
      #|    } else {
      #|      return gc_values[mid]
      #|    }
      #|  }
      #|
      #|  29 // Cn (Unassigned)
      #|}
      #|
    ),
  )
  out.finish()
}

///|
fn merged_full_mapping(
  simple : Array[SimpleMappingEntry],
  special : Array[FullMappingEntry],
) -> Array[FullMappingEntry] {
  let result : Array[FullMappingEntry] = []
  for entry in simple {
    result.push({ code_point: entry.code_point, targets: [entry.target] })
  }
  for entry in special {
    match
      result.search_by(existing => existing.code_point == entry.code_point) {
      Some(index) => result[index] = entry
      None => result.push(entry)
    }
  }
  result.sort_by((left, right) => left.code_point - right.code_point)
  result
}

///|
fn write_simple_case_arrays(
  out : @emitter.Emitter,
  name : String,
  mappings : Array[SimpleMappingEntry],
) -> Unit {
  let (mapping_label, target_label) = match name {
    "upper" => ("uppercase", "Uppercase")
    "lower" => ("lowercase", "Lowercase")
    "title" => ("titlecase", "Titlecase")
    _ => (name, name)
  }
  let sorted = mappings.copy()
  sorted.sort_by((left, right) => left.code_point - right.code_point)
  out.write_int_array(
    "Code points with " + mapping_label + " mappings (sorted for binary search)",
    name + "_cps",
    sorted.map(entry => entry.code_point),
    hex=true,
  )
  out.write_int_array(
    target_label + " mapping targets",
    name + "_targets",
    sorted.map(entry => entry.target),
    hex=true,
  )
}

///|
fn write_full_case_arrays(
  out : @emitter.Emitter,
  name : String,
  mappings : Array[FullMappingEntry],
) -> Unit {
  let sorted = mappings.copy()
  sorted.sort_by((left, right) => left.code_point - right.code_point)
  let starts : Array[Int] = []
  let lens : Array[Int] = []
  let data : Array[Int] = []
  for entry in sorted {
    starts.push(data.length())
    lens.push(entry.targets.length())
    data.append(entry.targets)
  }
  out.write_int_array(
    "Code points with full " + name + " mappings (sorted for binary search)",
    "full_" + name + "_cps",
    sorted.map(entry => entry.code_point),
    hex=true,
  )
  out.write_int_array(
    "Data start index for each full " + name + " mapping",
    "full_" + name + "_data_starts",
    starts,
    hex=false,
  )
  out.write_int_array(
    "Length of each full " + name + " mapping",
    "full_" + name + "_lens",
    lens,
    hex=false,
  )
  out.write_int_array(
    "Flattened full " + name + " mapping target code points",
    "full_" + name + "_data",
    data,
    hex=true,
  )
}

///|
pub fn emit_case_mapping(
  data : UnicodeData,
  special_casing : SpecialCasingData,
) -> String {
  let out = @emitter.Emitter::new()
  out.write_file_header("Simple case mapping lookup data", "UnicodeData.txt")
  write_simple_case_arrays(out, "upper", data.simple_uppercase)
  write_simple_case_arrays(out, "lower", data.simple_lowercase)
  write_simple_case_arrays(out, "title", data.simple_titlecase)
  out.write(
    (
      #|///|
      #|/// Binary search helper - returns index if found, -1 otherwise
      #|fn binary_search_case(arr : FixedArray[Int], cp : Int) -> Int {
      #|  let mut left = 0
      #|  let mut right = arr.length() - 1
      #|
      #|  while left <= right {
      #|    let mid = (left + right) / 2
      #|    let mid_cp = arr[mid]
      #|
      #|    if cp < mid_cp {
      #|      right = mid - 1
      #|    } else if cp > mid_cp {
      #|      left = mid + 1
      #|    } else {
      #|      return mid
      #|    }
      #|  }
      #|
      #|  -1
      #|}
      #|
      #|///|
      #|/// Look up simple uppercase mapping for a character
      #|/// Returns the character itself if no mapping exists
      #|pub fn lookup_simple_uppercase(c : Char) -> Char {
      #|  let cp = c.to_int()
      #|  let idx = binary_search_case(upper_cps, cp)
      #|  if idx >= 0 {
      #|    upper_targets[idx].unsafe_to_char()
      #|  } else {
      #|    c
      #|  }
      #|}
      #|
      #|///|
      #|/// Look up simple lowercase mapping for a character
      #|/// Returns the character itself if no mapping exists
      #|pub fn lookup_simple_lowercase(c : Char) -> Char {
      #|  let cp = c.to_int()
      #|  let idx = binary_search_case(lower_cps, cp)
      #|  if idx >= 0 {
      #|    lower_targets[idx].unsafe_to_char()
      #|  } else {
      #|    c
      #|  }
      #|}
      #|
      #|///|
      #|/// Look up simple titlecase mapping for a character
      #|/// Returns the character itself if no mapping exists
      #|pub fn lookup_simple_titlecase(c : Char) -> Char {
      #|  let cp = c.to_int()
      #|  let idx = binary_search_case(title_cps, cp)
      #|  if idx >= 0 {
      #|    title_targets[idx].unsafe_to_char()
      #|  } else {
      #|    c
      #|  }
      #|}
      #|
    ),
  )
  out.write("\n")
  write_full_case_arrays(
    out,
    "upper",
    merged_full_mapping(data.simple_uppercase, special_casing.upper_mapping),
  )
  write_full_case_arrays(
    out,
    "lower",
    merged_full_mapping(data.simple_lowercase, special_casing.lower_mapping),
  )
  write_full_case_arrays(
    out,
    "title",
    merged_full_mapping(data.simple_titlecase, special_casing.title_mapping),
  )
  out.write(
    (
      #|///|
      #|/// Look up full uppercase mapping for a character
      #|/// Returns Some(array of chars) if a mapping exists, None otherwise
      #|pub fn lookup_full_uppercase(c : Char) -> Array[Char]? {
      #|  let cp = c.to_int()
      #|  let idx = binary_search_case(full_upper_cps, cp)
      #|  if idx < 0 {
      #|    return None
      #|  }
      #|  let start = full_upper_data_starts[idx]
      #|  let len = full_upper_lens[idx]
      #|  let result : Array[Char] = []
      #|  for i = 0; i < len; i = i + 1 {
      #|    result.push(full_upper_data[start + i].unsafe_to_char())
      #|  }
      #|  Some(result)
      #|}
      #|
      #|///|
      #|/// Look up full lowercase mapping for a character
      #|/// Returns Some(array of chars) if a mapping exists, None otherwise
      #|pub fn lookup_full_lowercase(c : Char) -> Array[Char]? {
      #|  let cp = c.to_int()
      #|  let idx = binary_search_case(full_lower_cps, cp)
      #|  if idx < 0 {
      #|    return None
      #|  }
      #|  let start = full_lower_data_starts[idx]
      #|  let len = full_lower_lens[idx]
      #|  let result : Array[Char] = []
      #|  for i = 0; i < len; i = i + 1 {
      #|    result.push(full_lower_data[start + i].unsafe_to_char())
      #|  }
      #|  Some(result)
      #|}
      #|
      #|///|
      #|/// Look up full titlecase mapping for a character
      #|/// Returns Some(array of chars) if a mapping exists, None otherwise
      #|pub fn lookup_full_titlecase(c : Char) -> Array[Char]? {
      #|  let cp = c.to_int()
      #|  let idx = binary_search_case(full_title_cps, cp)
      #|  if idx < 0 {
      #|    return None
      #|  }
      #|  let start = full_title_data_starts[idx]
      #|  let len = full_title_lens[idx]
      #|  let result : Array[Char] = []
      #|  for i = 0; i < len; i = i + 1 {
      #|    result.push(full_title_data[start + i].unsafe_to_char())
      #|  }
      #|  Some(result)
      #|}
      #|
    ),
  )
  out.finish()
}

///|
pub fn emit_decomposition(data : UnicodeData) -> String {
  let entries : Array[DecompositionEntry] = []
  for entry in data.canonical_decompositions {
    entries.push(entry)
  }
  for compat in data.compatibility_decompositions {
    if entries.search_by(entry => entry.code_point == compat.code_point) is None {
      entries.push({ code_point: compat.code_point, code_points: [] })
    }
  }
  entries.sort_by((left, right) => left.code_point - right.code_point)
  let cps : Array[Int] = []
  let starts : Array[Int] = []
  let canonical_lens : Array[Int] = []
  let compat_lens : Array[Int] = []
  let flattened : Array[Int] = []
  for entry in entries {
    cps.push(entry.code_point)
    starts.push(flattened.length())
    match
      data.canonical_decompositions.search_by(item => {
        item.code_point == entry.code_point
      }) {
      Some(index) => {
        let canonical = data.canonical_decompositions[index].code_points
        canonical_lens.push(canonical.length())
        flattened.append(canonical)
      }
      None => canonical_lens.push(0)
    }
    match
      data.compatibility_decompositions.search_by(item => {
        item.code_point == entry.code_point
      }) {
      Some(index) => {
        let compat = data.compatibility_decompositions[index].code_points
        compat_lens.push(compat.length())
        flattened.append(compat)
      }
      None => compat_lens.push(0)
    }
  }
  let out = @emitter.Emitter::new()
  out.write_file_header("Decomposition mapping data", "UnicodeData.txt")
  out.write_int_array(
    "Code points with decomposition mappings (sorted for binary search)",
    "decomp_cps",
    cps,
    hex=true,
  )
  out.write_int_array(
    "Data start index for each code point",
    "decomp_data_starts",
    starts,
    hex=false,
  )
  out.write_int_array(
    "Canonical decomposition length (0 if none)",
    "decomp_canonical_lens",
    canonical_lens,
    hex=false,
  )
  out.write_int_array(
    "Compatibility decomposition length (0 if none)",
    "decomp_compat_lens",
    compat_lens,
    hex=false,
  )
  out.write_int_array(
    "Decomposition data (flattened code points)",
    "decomp_data",
    flattened,
    hex=true,
  )
  out.write(
    (
      #|///|
      #|/// Binary search for character index, returns -1 if not found
      #|fn find_decomp_index(c : Char) -> Int {
      #|  let cp = c.to_int()
      #|  let mut left = 0
      #|  let mut right = decomp_cps.length() - 1
      #|
      #|  while left <= right {
      #|    let mid = (left + right) / 2
      #|    let mid_cp = decomp_cps[mid]
      #|
      #|    if cp < mid_cp {
      #|      right = mid - 1
      #|    } else if cp > mid_cp {
      #|      left = mid + 1
      #|    } else {
      #|      return mid
      #|    }
      #|  }
      #|
      #|  -1
      #|}
      #|
      #|///|
      #|/// Get canonical decomposition for a character
      #|/// Returns None if no decomposition exists
      #|pub fn get_canonical_decomposition(c : Char) -> Array[Char]? {
      #|  let idx = find_decomp_index(c)
      #|  if idx < 0 {
      #|    return None
      #|  }
      #|
      #|  let len = decomp_canonical_lens[idx]
      #|  if len == 0 {
      #|    return None
      #|  }
      #|
      #|  let start = decomp_data_starts[idx]
      #|  let result : Array[Char] = []
      #|  for i = 0; i < len; i = i + 1 {
      #|    result.push(decomp_data[start + i].unsafe_to_char())
      #|  }
      #|  Some(result)
      #|}
      #|
      #|///|
      #|/// Get compatibility decomposition for a character
      #|/// Returns None if no decomposition exists
      #|pub fn get_compat_decomposition(c : Char) -> Array[Char]? {
      #|  let idx = find_decomp_index(c)
      #|  if idx < 0 {
      #|    return None
      #|  }
      #|
      #|  let compat_len = decomp_compat_lens[idx]
      #|  if compat_len == 0 {
      #|    return None
      #|  }
      #|
      #|  // Compat data comes after canonical data
      #|  let canonical_len = decomp_canonical_lens[idx]
      #|  let start = decomp_data_starts[idx] + canonical_len
      #|  let result : Array[Char] = []
      #|  for i = 0; i < compat_len; i = i + 1 {
      #|    result.push(decomp_data[start + i].unsafe_to_char())
      #|  }
      #|  Some(result)
      #|}
      #|
    ),
  )
  out.finish()
}

///|
pub fn emit_composition(
  compositions : Array[CompositionEntry],
  exclusions : Array[Int],
) -> String {
  let out = @emitter.Emitter::new()
  out.write_file_header(
    "Composition lookup data", "UnicodeData.txt and CompositionExclusions.txt",
  )
  out.write_int_array(
    "First code points of composition pairs (sorted)",
    "comp_firsts",
    compositions.map(entry => entry.first),
    hex=true,
  )
  out.write_int_array(
    "Second code points of composition pairs",
    "comp_seconds",
    compositions.map(entry => entry.second),
    hex=true,
  )
  out.write_int_array(
    "Composed result code points",
    "comp_results",
    compositions.map(entry => entry.result),
    hex=true,
  )
  out.write_int_array(
    "Composition exclusions (sorted for binary search)",
    "comp_exclusions",
    exclusions,
    hex=true,
  )
  out.write(
    (
      #|///|
      #|/// Look up composition for a pair of characters
      #|/// Returns Some(composed) if composition exists, None otherwise
      #|pub fn lookup_composition(starter : Char, combining : Char) -> Char? {
      #|  let starter_cp = starter.to_int()
      #|  let combining_cp = combining.to_int()
      #|  // Binary search for the pair
      #|  let mut left = 0
      #|  let mut right = comp_firsts.length() - 1
      #|
      #|  while left <= right {
      #|    let mid = (left + right) / 2
      #|    let mid_first = comp_firsts[mid]
      #|    let mid_second = comp_seconds[mid]
      #|
      #|    if starter_cp < mid_first ||
      #|      (starter_cp == mid_first && combining_cp < mid_second) {
      #|      right = mid - 1
      #|    } else if starter_cp > mid_first ||
      #|      (starter_cp == mid_first && combining_cp > mid_second) {
      #|      left = mid + 1
      #|    } else {
      #|      return Some(comp_results[mid].unsafe_to_char())
      #|    }
      #|  }
      #|
      #|  None
      #|}
      #|
      #|///|
      #|/// Check if a character is excluded from composition
      #|pub fn is_composition_excluded(c : Char) -> Bool {
      #|  let cp = c.to_int()
      #|  // Binary search in exclusions
      #|  let mut left = 0
      #|  let mut right = comp_exclusions.length() - 1
      #|
      #|  while left <= right {
      #|    let mid = (left + right) / 2
      #|    let mid_cp = comp_exclusions[mid]
      #|
      #|    if cp < mid_cp {
      #|      right = mid - 1
      #|    } else if cp > mid_cp {
      #|      left = mid + 1
      #|    } else {
      #|      return true
      #|    }
      #|  }
      #|
      #|  false
      #|}
      #|
    ),
  )
  out.finish()
}
