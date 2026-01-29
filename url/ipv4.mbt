///|
/// Represents an IPv4 address as a 32-bit unsigned integer
struct IPv4(UInt)

///|
/// Serialize IPv4 address to dotted-decimal notation (e.g., "192.168.1.1")
pub fn IPv4::to_string(self : IPv4) -> String {
  let n = self.0
  let b0 = (n >> 24) & 0xFF
  let b1 = (n >> 16) & 0xFF
  let b2 = (n >> 8) & 0xFF
  let b3 = n & 0xFF
  "\{b0}.\{b1}.\{b2}.\{b3}"
}

///|
/// Implement Show trait for IPv4, outputting dotted-decimal notation
pub impl Show for IPv4 with output(self : IPv4, logger : &Logger) -> Unit {
  logger.write_string(self.to_string())
}

///|
/// Implement ToJson trait for IPv4, outputting as array of 4 bytes
pub impl ToJson for IPv4 with to_json(self : IPv4) -> Json {
  let b0 = ((self.0 >> 24) & 0xFF).to_byte()
  let b1 = ((self.0 >> 16) & 0xFF).to_byte()
  let b2 = ((self.0 >> 8) & 0xFF).to_byte()
  let b3 = (self.0 & 0xFF).to_byte()
  [b0, b1, b2, b3].to_json()
}

///|
/// Parse an IPv4 address per WHATWG URL spec.
/// Supports decimal, octal (0-prefix), and hexadecimal (0x-prefix) notation.
pub fn IPv4::parse(input : StringView) -> IPv4 raise ValidationError {
  let parts = input.split(".").collect()
  let parts = if parts is [.. parts, ""] { parts } else { parts }
  if parts.length() > 4 {
    raise IPv4TooManyParts
  }
  let numbers = []
  for part in parts {
    let number = IPv4::parse_number(part)
    numbers.push(number)
  }
  guard numbers is [.. numbers, last_number] else { abort("unreachable") }
  for number in numbers {
    if number > 255 {
      raise IPv4OutOfRangePart
    }
  }
  if last_number >= 1UL << (8 * (4 - numbers.length())) {
    raise IPv4OutOfRangePart
  }
  let mut ipv4 = last_number.to_uint()
  let mut counter = 0
  for n in numbers {
    ipv4 = ipv4 + (n.to_uint() << (8 * (3 - counter)))
    counter = counter + 1
  }
  IPv4(ipv4)
}

///|
fn IPv4::parse_number(input : StringView) -> UInt64 raise ValidationError {
  if input is "" {
    raise IPv4EmptyPart
  }
  match input {
    ['0', 'x' | 'X', .. rest] => {
      // Hexadecimal
      let mut value : UInt64 = 0
      for c in rest {
        let digit = match c {
          '0'..='9' => c.to_int() - '0'
          'a'..='f' => c.to_int() - 'a' + 10
          'A'..='F' => c.to_int() - 'A' + 10
          _ => raise IPv4NonNumericPart
        }
        guard digit < 16 else { raise IPv4NonNumericPart }
        value = value * 16 + digit.to_uint64()
      }
      value
    }
    ['0', '0'..='9' as c, .. rest] => {
      // Octal (starts with 0 followed by digits)
      guard c >= '0' && c <= '7' else { raise IPv4NonNumericPart }
      let mut value : UInt64 = (c.to_int() - '0').to_uint64()
      for c in rest {
        guard c >= '0' && c <= '7' else { raise IPv4NonNumericPart }
        value = value * 8 + (c.to_int() - '0').to_uint64()
      }
      value
    }
    ['0'] => 0UL // Single zero is decimal 0
    ['1'..='9' as c, .. rest] => {
      // Decimal (starts with 1-9)
      let mut value : UInt64 = (c.to_int() - '0').to_uint64()
      for c in rest {
        guard c >= '0' && c <= '9' else { raise IPv4NonNumericPart }
        value = value * 10 + (c.to_int() - '0').to_uint64()
      }
      value
    }
    _ => raise IPv4NonNumericPart
  }
}

///|
test "IPv4::parse" {
  let inputs = ["127.0.0.1", "0xffffffff"]
  json_inspect(inputs.map(input => try? IPv4::parse(input)), content=[
    { "Ok": [127, 0, 0, 1] },
    { "Ok": [255, 255, 255, 255] },
  ])
}

///|
test "IPv4::parse_number" {
  json_inspect(IPv4::parse_number("255"), content="255")
  json_inspect(IPv4::parse_number("0xff"), content="255")
  json_inspect(IPv4::parse_number("0377"), content="255")
  json_inspect(try? IPv4::parse_number("09"), content={
    "Err": "IPv4NonNumericPart",
  })
}
