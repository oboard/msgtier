///|
priv struct CccEntry {
  code_point : Int
  value : Int
}

///|
priv struct DecompositionEntry {
  code_point : Int
  code_points : Array[Int]
}

///|
priv struct GeneralCategoryEntry {
  code_point : Int
  category : String
}

///|
priv struct SimpleMappingEntry {
  code_point : Int
  target : Int
}

///|
priv struct FullMappingEntry {
  code_point : Int
  targets : Array[Int]
}

///|
struct UnicodeData {
  ccc_entries : Array[CccEntry]
  canonical_decompositions : Array[DecompositionEntry]
  compatibility_decompositions : Array[DecompositionEntry]
  mark_code_points : Array[Int]
  general_categories : Array[GeneralCategoryEntry]
  simple_uppercase : Array[SimpleMappingEntry]
  simple_lowercase : Array[SimpleMappingEntry]
  simple_titlecase : Array[SimpleMappingEntry]
}

///|
struct SpecialCasingData {
  lower_mapping : Array[FullMappingEntry]
  title_mapping : Array[FullMappingEntry]
  upper_mapping : Array[FullMappingEntry]
}

///|
struct CodePointRange {
  start : Int
  end : Int
}

///|
struct CccRange {
  start : Int
  end : Int
  value : Int
}

///|
struct GeneralCategoryRange {
  start : Int
  end : Int
  value : Int
}

///|
struct CompositionEntry {
  first : Int
  second : Int
  result : Int
}
