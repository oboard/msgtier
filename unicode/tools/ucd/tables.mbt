///|
fn sorted_ints(values : Array[Int]) -> Array[Int] {
  let sorted = values.copy()
  sorted.sort()
  sorted
}

///|
fn contains_int(values : Array[Int], target : Int) -> Bool {
  values.any(value => value == target)
}

///|
fn ccc_for(data : UnicodeData, cp : Int) -> Int {
  match data.ccc_entries.search_by(entry => entry.code_point == cp) {
    Some(index) => data.ccc_entries[index].value
    None => 0
  }
}

///|
fn gc_ordinal(category : String) -> Int {
  match category {
    "Lu" => 0
    "Ll" => 1
    "Lt" => 2
    "Lm" => 3
    "Lo" => 4
    "Mn" => 5
    "Mc" => 6
    "Me" => 7
    "Nd" => 8
    "Nl" => 9
    "No" => 10
    "Zs" => 11
    "Zl" => 12
    "Zp" => 13
    "Pc" => 14
    "Pd" => 15
    "Ps" => 16
    "Pe" => 17
    "Pi" => 18
    "Pf" => 19
    "Po" => 20
    "Sm" => 21
    "Sc" => 22
    "Sk" => 23
    "So" => 24
    "Cc" => 25
    "Cf" => 26
    "Cs" => 27
    "Co" => 28
    _ => 29
  }
}

///|
pub fn compress_ccc_ranges(data : UnicodeData) -> Array[CccRange] {
  let entries = data.ccc_entries.copy()
  entries.sort_by((left, right) => left.code_point - right.code_point)
  let ranges : Array[CccRange] = []
  if entries.length() == 0 {
    return ranges
  }
  let mut start = entries[0].code_point
  let mut prev_cp = start
  let mut prev_value = entries[0].value
  for entry in entries.view(start=1) {
    if entry.code_point == prev_cp + 1 && entry.value == prev_value {
      prev_cp = entry.code_point
    } else {
      ranges.push({ start, end: prev_cp, value: prev_value })
      start = entry.code_point
      prev_cp = entry.code_point
      prev_value = entry.value
    }
  }
  ranges.push({ start, end: prev_cp, value: prev_value })
  ranges
}

///|
pub fn compress_mark_ranges(data : UnicodeData) -> Array[CodePointRange] {
  let cps = sorted_ints(data.mark_code_points)
  let ranges : Array[CodePointRange] = []
  if cps.length() == 0 {
    return ranges
  }
  let mut start = cps[0]
  let mut prev_cp = start
  for cp in cps.view(start=1) {
    if cp == prev_cp + 1 {
      prev_cp = cp
    } else {
      ranges.push({ start, end: prev_cp })
      start = cp
      prev_cp = cp
    }
  }
  ranges.push({ start, end: prev_cp })
  ranges
}

///|
pub fn compress_general_category_ranges(
  data : UnicodeData,
) -> Array[GeneralCategoryRange] {
  let entries = data.general_categories.copy()
  entries.sort_by((left, right) => left.code_point - right.code_point)
  let ranges : Array[GeneralCategoryRange] = []
  if entries.length() == 0 {
    return ranges
  }
  let max_cp = entries[entries.length() - 1].code_point
  let mut entry_index = 0
  let mut start = 0
  let mut prev_cp = -1
  let mut prev_value = -1
  for cp in 0..<=max_cp {
    let value = if entry_index < entries.length() &&
      entries[entry_index].code_point == cp {
      let current = gc_ordinal(entries[entry_index].category)
      entry_index += 1
      current
    } else {
      29
    }
    if cp == prev_cp + 1 && value == prev_value {
      prev_cp = cp
    } else {
      if prev_value >= 0 {
        ranges.push({ start, end: prev_cp, value: prev_value })
      }
      start = cp
      prev_cp = cp
      prev_value = value
    }
  }
  if prev_value >= 0 {
    ranges.push({ start, end: prev_cp, value: prev_value })
  }
  ranges
}

///|
pub fn build_composition_table(
  data : UnicodeData,
  exclusions : Array[Int],
) -> Array[CompositionEntry] {
  let compositions : Array[CompositionEntry] = []
  for decomp in data.canonical_decompositions {
    if decomp.code_points.length() == 2 &&
      !contains_int(exclusions, decomp.code_point) {
      compositions.push({
        first: decomp.code_points[0],
        second: decomp.code_points[1],
        result: decomp.code_point,
      })
    }
  }
  compositions.sort_by((left, right) => {
    let first_order = left.first - right.first
    if first_order != 0 {
      first_order
    } else {
      left.second - right.second
    }
  })
  compositions
}

///|
pub fn build_full_composition_exclusions(
  data : UnicodeData,
  explicit_exclusions : Array[Int],
) -> Array[Int] {
  let exclusions = explicit_exclusions.copy()
  for decomp in data.canonical_decompositions {
    if decomp.code_points.length() == 1 {
      if !contains_int(exclusions, decomp.code_point) {
        exclusions.push(decomp.code_point)
      }
    } else if decomp.code_points.length() > 0 &&
      ccc_for(data, decomp.code_points[0]) > 0 {
      if !contains_int(exclusions, decomp.code_point) {
        exclusions.push(decomp.code_point)
      }
    }
  }
  exclusions.sort()
  exclusions
}
