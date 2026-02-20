///|
/// Represents a URL host per the WHATWG URL Standard.
/// Can be a domain name, IPv4 address, IPv6 address, or opaque string.
pub enum Host {
  Domain(String)
  IPv4(IPv4)
  IPv6(IPv6)
  Opaque(String)
} derive(Debug, ToJson)

///|
pub impl FromJson for Host with from_json(json, path) raise @json.JsonDecodeError {
  match json {
    String(s) =>
      Host::parse(s) catch {
        _ => raise @json.JsonDecodeError((path, "Invalid host \{json}"))
      }
    _ => raise @json.JsonDecodeError((path, "Invalid host \{json}"))
  }
}

///|
/// Serialize host per WHATWG URL spec
pub fn Host::to_string(self : Host) -> String {
  match self {
    Domain(domain) => domain
    IPv4(ipv4) => ipv4.to_string()
    IPv6(ipv6) => "[\{ipv6.to_string()}]"
    Opaque(opaque_) => opaque_
  }
}

///|
/// Implement Show trait for Host, outputting the serialized host string
pub impl Show for Host with output(self : Host, logger : &Logger) -> Unit {
  logger.write_string(self.to_string())
}

///|
/// Convert host to Unicode form for display (Punycode → Unicode)
pub fn Host::to_unicode(self : Host) -> String {
  match self {
    Domain(domain) =>
      @idna.to_unicode(domain) catch {
        _ => domain // If IDNA conversion fails, return as-is
      }
    IPv4(ipv4) => ipv4.to_string()
    IPv6(ipv6) => "[\{ipv6.to_string()}]"
    Opaque(s) => s
  }
}

///|
/// URL parsing validation errors per the WHATWG URL Standard.
/// Each variant represents a specific parsing failure condition.
suberror ValidationError {
  DomainToAscii
  HostInvalidCodePoint
  IPv4EmptyPart
  IPv4TooManyParts
  IPv4NonNumericPart
  IPv4OutOfRangePart
  IPv6InvalidCompression
  IPv6MultipleCompression
  IPv6TooManyPieces
  IPv6InvalidCodePoint
  IPv6TooFewPieces
  IPv6Unclosed
  IPv4InIPv6InvalidCodePoint
  IPv4InIPv6TooManyPieces
  IPv4InIPv6OutOfRangePart
  IPv4InIPv6TooFewParts
  MissingSchemeNonRelativeUrl
  SpecialSchemeMissingFollowingSolidus
  InvalidReverseSolidus
  InvalidCredentials
  HostMissing
} derive(ToJson)

///|
fn percent_decode_string(input : StringView) -> Bytes {
  let bytes = @utf8.encode(input, bom=false)
  return percent_decode_bytes(bytes)
}

///|
fn percent_decode_bytes(input : Bytes) -> Bytes {
  let output = @buffer.new()
  loop input[:] {
    ['%', c0, c1, .. rest] as view => {
      let b0 = match c0 {
        '0'..='9' => c0.to_int() - '0'.to_int()
        'a'..='f' => c0.to_int() - 'a'.to_int() + 10
        'A'..='F' => c0.to_int() - 'A'.to_int() + 10
        _ => {
          output.write_byte('%')
          continue view[1:]
        }
      }
      let b1 = match c1 {
        '0'..='9' => c1.to_int() - '0'.to_int()
        'a'..='f' => c1.to_int() - 'a'.to_int() + 10
        'A'..='F' => c1.to_int() - 'A'.to_int() + 10
        _ => {
          output.write_byte('%')
          output.write_byte(c0)
          continue view[2:]
        }
      }
      output.write_byte(((b0 << 4) | b1).to_byte())
      continue rest
    }
    [byte, .. rest] => {
      output.write_byte(byte)
      continue rest
    }
    [] => break
  }
  output.contents()
}

///|
/// Check if a string contains any forbidden domain code point per WHATWG URL spec
/// Forbidden domain code points = forbidden host code points + C0 controls + % + DEL
fn contains_forbidden_domain_codepoint(s : String) -> Bool {
  for c in s {
    // C0 controls (U+0000-U+001F) and DEL (U+007F)
    if c is ('\u{0000}'..='\u{001f}' | '\u{007f}') {
      return true
    }
    // Forbidden host code points plus %
    if c
      is (' '
      | '#'
      | '%'
      | '/'
      | ':'
      | '<'
      | '>'
      | '?'
      | '@'
      | '['
      | '\\'
      | ']'
      | '^'
      | '|') {
      return true
    }
  }
  false
}

///|
/// Parse a host string per WHATWG URL spec.
/// Handles IPv4, IPv6 (in brackets), domain names with IDNA/Punycode, and opaque hosts.
pub fn Host::parse(
  input : StringView,
  is_opaque? : Bool = false,
) -> Host raise ValidationError {
  match input {
    ['[', .. rest, ']'] => {
      let ipv6 = IPv6::parse(rest)
      IPv6(ipv6)
    }
    ['[', ..] => raise IPv6Unclosed
    input => {
      if is_opaque {
        let opaque_host = Host::parse_opaque(input)
        return Host::Opaque(opaque_host)
      }
      let domain = @utf8.decode_lossy(percent_decode_string(input))
      // Use IDNA to convert internationalized domain names to ASCII (Punycode)
      // Per WHATWG, empty labels are allowed (unlike strict DNS/IDNA)
      let ascii_domain = @idna.to_ascii(
        domain,
        use_std3_ascii_rules=false,
        verify_dns_length=false,
      ) catch {
        @idna.EmptyLabel => {
          // Allow empty labels per WHATWG only if domain consists of
          // valid ASCII domain characters (intentional empty labels like "." or "..")
          // Reject if empty label comes from IDNA mapping (e.g., soft hyphen -> "")
          let is_valid_ascii_domain = domain
            .iter()
            .all(fn(c) {
              c.is_ascii_lowercase() ||
              c.is_ascii_uppercase() ||
              c.is_ascii_digit() ||
              c is ('.' | '-')
            })
          if is_valid_ascii_domain && !domain.is_empty() {
            domain
          } else {
            raise DomainToAscii
          }
        }
        _ => {
          // Per WHATWG: If IDNA fails but the string is ASCII and doesn't
          // contain forbidden domain code points, use it as-is
          // This allows hosts like `!"$&'()*+,-.;=_`{}~` which are valid per spec
          // BUT: domains containing "xn--" labels must be valid punycode - reject if IDNA fails
          let is_ascii = domain.iter().all(fn(c) { c.to_int() < 128 })
          let has_punycode_label = domain.to_lower().contains("xn--")
          if is_ascii &&
            !contains_forbidden_domain_codepoint(domain) &&
            !has_punycode_label {
            domain
          } else {
            raise DomainToAscii
          }
        }
      }
      // Check for forbidden domain code points after IDNA conversion
      if contains_forbidden_domain_codepoint(ascii_domain) {
        raise HostInvalidCodePoint
      }
      if ends_in_a_number(ascii_domain) {
        return IPv4(IPv4::parse(ascii_domain))
      }
      return Domain(ascii_domain)
    }
  }
}

///|
fn ends_in_a_number(input : StringView) -> Bool {
  let parts = input.split(".").collect()
  match parts {
    [] | [""] => return false
    [.., last, ""] | [.., last] => {
      if last is "" {
        return false
      }
      match last {
        ['0', 'x' | 'X', .. last] =>
          for c in last {
            if c is ('0'..='9' | 'a'..='f' | 'A'..='F') {
              continue
            } else {
              return false
            }
          } nobreak {
            return true
          }
        ['0'..='9', .. last] =>
          for c in last {
            if c is ('0'..='9') {
              continue
            } else {
              return false
            }
          } nobreak {
            return true
          }
        _ => return false
      }
    }
  }
}

///|
test "ends_in_a_number" {
  json_inspect(ends_in_a_number("example.com.123"), content=true)
  json_inspect(!ends_in_a_number("example.com.abc"), content=true)
  json_inspect(!ends_in_a_number("example.com."), content=true)
  json_inspect(!ends_in_a_number("example.com"), content=true)
  json_inspect(ends_in_a_number("example.0x1A"), content=true)
  json_inspect(!ends_in_a_number("example.0xG1"), content=true)
  json_inspect(!ends_in_a_number("example.09"), content=false)
  json_inspect(ends_in_a_number("0xffffffff"), content=true)
}

///|
/// Parse an opaque host per WHATWG URL spec
/// Only rejects forbidden host code points, accepts everything else
fn Host::parse_opaque(input : StringView) -> String raise ValidationError {
  // Check for forbidden host code points
  for c in input {
    if c
      is ('\u{0000}'
      | '\u{0009}'
      | '\u{000a}'
      | '\u{000d}'
      | ' '
      | '#'
      | '/'
      | ':'
      | '<'
      | '>'
      | '?'
      | '@'
      | '['
      | '\\'
      | ']'
      | '^'
      | '|') {
      raise HostInvalidCodePoint
    }
  }
  // Percent-encode C0 controls in the output
  utf8_percent_encode(input, c0_control_percent_encode_set)
}

///|
let hex_digits : ReadOnlyArray[Char] = [
  '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F',
]

///|
fn c0_control_percent_encode_set(char : Char) -> Bool {
  return char is ('\u{0000}'..='\u{001f}' | '\u{007f}'..<_)
}

///|
fn query_percent_encode_set(char : Char) -> Bool {
  return char
    is ('\u{0000}'..='\u{001f}' | '\u{007f}'..<_ | ' ' | '"' | '#' | '<' | '>')
}

///|
/// Special query percent-encode set: query set + single quote (for http/https)
fn special_query_percent_encode_set(char : Char) -> Bool {
  return char
    is ('\u{0000}'..='\u{001f}'
    | '\u{007f}'..<_
    | ' '
    | '"'
    | '#'
    | '<'
    | '>'
    | '\'')
}

///|
/// Fragment percent-encode set: C0 control + space + "<>`
fn fragment_percent_encode_set(char : Char) -> Bool {
  return char
    is ('\u{0000}'..='\u{001f}' | '\u{007f}'..<_ | ' ' | '"' | '<' | '>' | '`')
}

///|
fn path_percent_encode_set(char : Char) -> Bool {
  return char
    is ('\u{0000}'..='\u{001f}'
    | '\u{007f}'..<_
    | ' '
    | '"'
    | '#'
    | '<'
    | '>'
    | '?'
    | '^'
    | '`'
    | '{'
    | '}')
}

///|
fn userinfo_percent_encode_set(char : Char) -> Bool {
  return char
    is ('\u{0000}'..='\u{001f}'
    | '\u{007f}'..<_
    | ' '
    | '"'
    | '#'
    | '<'
    | '>'
    | '?'
    | '^'
    | '`'
    | '{'
    | '}'
    | '/'
    | ':'
    | ';'
    | '='
    | '@'
    | '['..=']'
    | '|')
}

///|
#locals(percent_encode_set)
fn utf8_percent_encode(
  input : StringView,
  percent_encode_set : (Char) -> Bool,
  space_as_plus? : Bool = false,
) -> String {
  let output = StringBuilder::new()
  let encode_output = @utf8.encode(input)
  for byte in encode_output {
    if space_as_plus && byte is ' ' {
      output.write_char('+')
      continue
    }
    let isomorph = byte.to_char()
    if percent_encode_set(isomorph) {
      output.write_char('%')
      let byte = byte.to_int()
      output.write_char(hex_digits[(byte >> 4) & 0x0f])
      output.write_char(hex_digits[byte & 0x0f])
      continue
    } else {
      output.write_char(isomorph)
    }
  }
  output.to_string()
}
