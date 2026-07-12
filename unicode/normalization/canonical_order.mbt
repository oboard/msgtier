///|
/// Canonical Ordering Algorithm
/// Sorts combining marks by Canonical Combining Class (CCC)
/// Uses stable sort to preserve order of marks with same CCC

///|
/// Reorder characters according to Canonical Combining Class
/// Starters (CCC=0) remain in place, combining marks are sorted by CCC
fn canonical_order(chars : Array[Char]) -> Unit {
  let len = chars.length()
  if len < 2 {
    return
  }
  let mut i = 0
  while i < len {
    let ccc = @ucd.lookup_ccc(chars[i])

    // Skip starters
    if ccc == 0 {
      i = i + 1
      continue
    }

    // Find the start of this combining mark sequence
    // (first non-starter after a starter or beginning)
    let start = i

    // Find the end of the combining mark sequence
    while i < len && @ucd.lookup_ccc(chars[i]) != 0 {
      i = i + 1
    }

    // Sort the combining marks by CCC using stable insertion sort
    // Insertion sort is ideal here because:
    // 1. Combining mark sequences are typically short (1-4 marks)
    // 2. It's stable (preserves order of same-CCC marks)
    // 3. Simple and efficient for small arrays
    if i > start + 1 {
      stable_sort_by_ccc(chars, start, i)
    }
  }
}

///|
/// Stable insertion sort by CCC for a range [start, end)
fn stable_sort_by_ccc(arr : Array[Char], start : Int, end : Int) -> Unit {
  let mut i = start + 1
  while i < end {
    let key = arr[i]
    let key_ccc = @ucd.lookup_ccc(key)
    let mut j = i - 1

    // Move elements with greater CCC to the right
    while j >= start && @ucd.lookup_ccc(arr[j]) > key_ccc {
      arr[j + 1] = arr[j]
      j = j - 1
    }
    arr[j + 1] = key
    i = i + 1
  }
}
