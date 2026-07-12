///|
let sample_unicode_data : String =
  #|0041;LATIN CAPITAL LETTER A;Lu;0;L;;;;;N;;;;0061;
  #|0061;LATIN SMALL LETTER A;Ll;0;L;;;;;N;;;0041;;0041
  #|00A0;NO-BREAK SPACE;Zs;0;CS;<noBreak> 0020;;;;N;;;;;
  #|00C0;LATIN CAPITAL LETTER A WITH GRAVE;Lu;0;L;0041 0300;;;;N;;;;00E0;
  #|0300;COMBINING GRAVE ACCENT;Mn;230;NSM;;;;;N;;;;;
  #|0301;COMBINING ACUTE ACCENT;Mn;230;NSM;;;;;N;;;;;
  #|AC00;HANGUL SYLLABLE GA;Lo;0;L;;;;;N;;;;;

///|
test "parse UnicodeData fields" {
  let data = parse_unicode_data(sample_unicode_data)
  inspect(data.ccc_entries.length(), content="2")
  inspect(data.canonical_decompositions.length(), content="1")
  inspect(data.compatibility_decompositions.length(), content="1")
  inspect(data.mark_code_points.length(), content="2")
  inspect(data.mark_code_points[0], content="768")
  inspect(data.mark_code_points[1], content="769")
  inspect(data.simple_uppercase.length(), content="1")
  inspect(data.simple_lowercase.length(), content="2")
  inspect(data.simple_titlecase.length(), content="1")
  inspect(
    data.general_categories.any(entry => entry.code_point == 0xAC00),
    content="false",
  )
}

///|
test "parse CompositionExclusions ranges" {
  let input =
    #|# comment
    #|0340
    #|0958..0959 # DEVANAGARI LETTER QA..KHHA
  let exclusions = parse_composition_exclusions(input)
  inspect(exclusions.length(), content="3")
  inspect(exclusions[0], content="832")
  inspect(exclusions[1], content="2392")
  inspect(exclusions[2], content="2393")
}

///|
test "parse SpecialCasing unconditional mappings only" {
  let input =
    #|00DF; 0073 0073; 0053 0073; 0053 0053; # LATIN SMALL LETTER SHARP S
    #|03A3; 03C3; 03A3; 03A3; Final_Sigma; # conditional, skipped
  let special = parse_special_casing(input)
  inspect(special.lower_mapping.length(), content="1")
  inspect(special.title_mapping[0].targets.length(), content="2")
  inspect(special.title_mapping[0].targets[0], content="83")
  inspect(special.title_mapping[0].targets[1], content="115")
  inspect(special.upper_mapping[0].targets.length(), content="2")
  inspect(special.upper_mapping[0].targets[0], content="83")
  inspect(special.upper_mapping[0].targets[1], content="83")
}

///|
test "compress ranges and build composition data" {
  let data = parse_unicode_data(sample_unicode_data)
  let ccc_ranges = compress_ccc_ranges(data)
  inspect(ccc_ranges.length(), content="1")
  inspect(ccc_ranges[0].start, content="768")
  inspect(ccc_ranges[0].end, content="769")
  inspect(ccc_ranges[0].value, content="230")
  let mark_ranges = compress_mark_ranges(data)
  inspect(mark_ranges[0].start, content="768")
  inspect(mark_ranges[0].end, content="769")
  let gc_ranges = compress_general_category_ranges(data)
  inspect(gc_ranges[0].start, content="0")
  inspect(gc_ranges[0].end, content="64")
  inspect(gc_ranges[0].value, content="29")
  let compositions = build_composition_table(data, [])
  inspect(compositions[0].first, content="65")
  inspect(compositions[0].second, content="768")
  inspect(compositions[0].result, content="192")
}

///|
test "build full composition exclusions" {
  let input =
    #|0300;COMBINING GRAVE ACCENT;Mn;230;NSM;;;;;N;;;;;
    #|0340;COMBINING GRAVE TONE MARK;Mn;230;NSM;0300;;;;N;;;;;
    #|0958;DEVANAGARI LETTER QA;Lo;0;L;0915 093C;;;;N;;;;;
  let data = parse_unicode_data(input)
  let exclusions = build_full_composition_exclusions(data, [0x0958])
  inspect(exclusions.length(), content="2")
  inspect(exclusions[0], content="832")
  inspect(exclusions[1], content="2392")
}

///|
test "emit small CCC table" {
  let source = emit_ccc([{ start: 0x0300, end: 0x0301, value: 230 }], [
    { start: 0x0300, end: 0x0301 },
  ])
  inspect(
    source.contains("let ccc_starts : FixedArray[Int] = ["),
    content="true",
  )
  inspect(source.contains("  0x0300"), content="true")
  inspect(source.contains("pub fn lookup_ccc(c : Char) -> Int"), content="true")
}

///|
test "emit decomposition and case mapping arrays" {
  let data = parse_unicode_data(sample_unicode_data)
  let input =
    #|00DF; 0073 0073; 0053 0073; 0053 0053; # LATIN SMALL LETTER SHARP S
  let special = parse_special_casing(input)
  inspect(
    emit_decomposition(data).contains("let decomp_cps : FixedArray[Int]"),
    content="true",
  )
  inspect(
    emit_case_mapping(data, special).contains(
      "let full_upper_cps : FixedArray[Int]",
    ),
    content="true",
  )
}
