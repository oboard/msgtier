///|
let cache_dir : String = "scripts/.cache"

///|
let output_dir : String = "internal/ucd"

///|
async fn read_cache_file(name : String) -> String {
  @fs.read_file(cache_dir + "/" + name).text()
}

///|
async fn write_generated_file(name : String, source : String) -> Unit {
  @fs.write_file(output_dir + "/" + name, source, create=0o644, truncate=true)
}

///|
async fn generate_ucd() -> Unit {
  let unicode_data = @ucd.parse_unicode_data(read_cache_file("UnicodeData.txt"))
  let exclusions = @ucd.parse_composition_exclusions(
    read_cache_file("CompositionExclusions.txt"),
  )
  let special_casing = @ucd.parse_special_casing(
    read_cache_file("SpecialCasing.txt"),
  )
  let ccc_ranges = @ucd.compress_ccc_ranges(unicode_data)
  let mark_ranges = @ucd.compress_mark_ranges(unicode_data)
  let general_category_ranges = @ucd.compress_general_category_ranges(
    unicode_data,
  )
  let compositions = @ucd.build_composition_table(unicode_data, exclusions)
  let full_exclusions = @ucd.build_full_composition_exclusions(
    unicode_data, exclusions,
  )
  write_generated_file("ccc.mbt", @ucd.emit_ccc(ccc_ranges, mark_ranges))
  write_generated_file(
    "decomposition.mbt",
    @ucd.emit_decomposition(unicode_data),
  )
  write_generated_file(
    "composition.mbt",
    @ucd.emit_composition(compositions, full_exclusions),
  )
  write_generated_file(
    "general_category.mbt",
    @ucd.emit_general_category(general_category_ranges),
  )
  write_generated_file(
    "case_mapping.mbt",
    @ucd.emit_case_mapping(unicode_data, special_casing),
  )
}

///|
async fn format_generated_files() -> Unit {
  let status = @process.run("moon", ["fmt", output_dir])
  if status != 0 {
    fail("moon fmt internal/ucd failed")
  }
}

///|
async fn main {
  let cmd = @argparse.Command("gen", subcommands=[
    @argparse.Command("ucd"),
    @argparse.Command("all"),
  ])
  let matches = cmd.parse() catch {
    err => fail(err.to_string())
  }
  match matches.subcommand {
    None | Some(("ucd", _)) | Some(("all", _)) => {
      generate_ucd()
      format_generated_files()
    }
    Some(_) => fail("unreachable subcommand")
  }
}
