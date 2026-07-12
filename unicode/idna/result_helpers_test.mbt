///|
fn to_ascii_result(
  domain : String,
  use_std3_ascii_rules? : Bool = true,
  check_hyphens? : Bool = true,
  check_bidi? : Bool = true,
  check_joiners? : Bool = true,
  verify_dns_length? : Bool = true,
) -> Result[String, @idna.IdnaError] {
  try
    @idna.to_ascii(
      domain,
      use_std3_ascii_rules~,
      check_hyphens~,
      check_bidi~,
      check_joiners~,
      verify_dns_length~,
    )
  catch {
    err => Err(err)
  } noraise {
    value => Ok(value)
  }
}

///|
fn to_unicode_result(
  domain : String,
  use_std3_ascii_rules? : Bool = true,
  check_hyphens? : Bool = true,
  check_bidi? : Bool = true,
  check_joiners? : Bool = true,
) -> Result[String, @idna.IdnaError] {
  try
    @idna.to_unicode(
      domain,
      use_std3_ascii_rules~,
      check_hyphens~,
      check_bidi~,
      check_joiners~,
    )
  catch {
    err => Err(err)
  } noraise {
    value => Ok(value)
  }
}

///|
fn[T] result_of(f : () -> T raise) -> Result[T, Error] {
  try f() catch {
    err => Err(err)
  } noraise {
    value => Ok(value)
  }
}
