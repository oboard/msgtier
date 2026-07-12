///|
/// Punycode encoding/decoding (RFC 3492)
/// Used for Internationalized Domain Names in Applications (IDNA)

///|
/// Error type for Punycode operations
pub(all) suberror PunycodeError {
  Overflow
  InvalidInput
  BadInput
}

///|
pub impl Show for PunycodeError with fn output(self, logger) {
  match self {
    Overflow => logger.write_string("Overflow")
    InvalidInput => logger.write_string("InvalidInput")
    BadInput => logger.write_string("BadInput")
  }
}

// RFC 3492 constants (Section 4)

///|
/// Base for variable-length integer encoding. Punycode uses base-36
/// (letters a-z represent 0-25, digits 0-9 represent 26-35).
const Base : Int = 36

///|
/// Minimum threshold for variable-length integer encoding.
/// Ensures at least one digit is always output.
const Tmin : Int = 1

///|
/// Maximum threshold for variable-length integer encoding.
/// Equals the number of lowercase letters (a-z).
const Tmax : Int = 26

///|
/// Skew parameter for bias adaptation function.
/// Controls how quickly the bias adjusts to character frequencies.
const Skew : Int = 38

///|
/// Damping factor applied only to the first delta value.
/// Prevents the bias from changing too rapidly at the start.
const Damp : Int = 700

///|
/// Initial bias value for the adaptation algorithm.
/// Chosen to work well for typical internationalized domain names.
const InitialBias : Int = 72

///|
/// Initial value of n, the threshold between basic ASCII (0-127)
/// and non-basic code points that require encoding.
const InitialN : Int = 0x80

///|
/// Delimiter character separating the basic ASCII portion
/// from the Punycode-encoded portion in the output.
const Delimiter : Char = '-'

///|
/// Bias adaptation function (RFC 3492 Section 3.4)
fn adapt(delta : Int, numpoints : Int, firsttime : Bool) -> Int {
  let mut delta = delta
  if firsttime {
    delta = delta / Damp
  } else {
    delta = delta / 2
  }
  delta = delta + delta / numpoints
  let mut k = 0
  while delta > (Base - Tmin) * Tmax / 2 {
    delta = delta / (Base - Tmin)
    k = k + Base
  }
  k + (Base - Tmin + 1) * delta / (delta + Skew)
}

///|
/// Encode a digit to a basic code point (a-z for 0-25, 0-9 for 26-35)
fn encode_digit(d : Int) -> Char {
  if d < 26 {
    (d + 'a'.to_int()).unsafe_to_char()
  } else {
    (d - 26 + '0'.to_int()).unsafe_to_char()
  }
}

///|
/// Decode a basic code point to a digit
fn decode_digit(cp : Int) -> Int {
  if cp >= 'a'.to_int() && cp <= 'z'.to_int() {
    cp - 'a'.to_int()
  } else if cp >= 'A'.to_int() && cp <= 'Z'.to_int() {
    cp - 'A'.to_int()
  } else if cp >= '0'.to_int() && cp <= '9'.to_int() {
    cp - '0'.to_int() + 26
  } else {
    Base // Invalid
  }
}

///|
/// Check if a character is a basic ASCII character (0-127)
fn is_basic(c : Char) -> Bool {
  c.to_int() < 0x80
}

///|
/// Encode a Unicode string to Punycode
pub fn encode(input : String) -> String raise PunycodeError {
  let output = StringBuilder::new()

  // Convert input to array of characters
  let chars : Array[Char] = []
  for c in input {
    chars.push(c)
  }

  // Copy all basic code points to output
  let mut basic_count = 0
  for c in chars {
    if is_basic(c) {
      output.write_char(c)
      basic_count = basic_count + 1
    }
  }

  // Add delimiter if there were basic characters
  let handled = basic_count
  if basic_count > 0 {
    output.write_char(Delimiter)
  }
  let mut n = InitialN
  let mut delta = 0
  let mut bias = InitialBias
  let mut handled = handled
  while handled < chars.length() {
    // Find the minimum code point >= n
    let mut m = 0x10FFFF + 1
    for c in chars {
      let cp = c.to_int()
      if cp >= n && cp < m {
        m = cp
      }
    }

    // Increase delta enough to advance the decoder's <n,i> state to <m,0>
    let delta_increment = (m - n) * (handled + 1)
    if delta > 0x7FFFFFFF - delta_increment {
      raise Overflow
    }
    delta = delta + delta_increment
    n = m
    for c in chars {
      let cp = c.to_int()
      if cp < n {
        delta = delta + 1
        if delta == 0 {
          raise Overflow
        }
      } else if cp == n {
        // Represent delta as a generalized variable-length integer
        let mut q = delta
        let mut k = Base
        while true {
          let t = if k <= bias {
            Tmin
          } else if k >= bias + Tmax {
            Tmax
          } else {
            k - bias
          }
          if q < t {
            break
          }
          output.write_char(encode_digit(t + (q - t) % (Base - t)))
          q = (q - t) / (Base - t)
          k = k + Base
        }
        output.write_char(encode_digit(q))
        bias = adapt(delta, handled + 1, handled == basic_count)
        delta = 0
        handled = handled + 1
      }
    }
    delta = delta + 1
    n = n + 1
  }
  output.to_string()
}

///|
/// Decode a Punycode string to Unicode
pub fn decode(input : String) -> String raise PunycodeError {
  let output : Array[Char] = []

  // Find the last delimiter
  let mut basic_end = -1
  let mut i = 0
  for c in input {
    if c == Delimiter {
      basic_end = i
    }
    i = i + 1
  }

  // Copy basic code points before the last delimiter
  if basic_end > 0 {
    let mut j = 0
    for c in input {
      if j >= basic_end {
        break
      }
      if !is_basic(c) {
        raise BadInput
      }
      output.push(c)
      j = j + 1
    }
  }

  // Main decoding loop
  let mut n = InitialN
  let mut i_val = 0
  let mut bias = InitialBias
  let mut in_pos = if basic_end >= 0 { basic_end + 1 } else { 0 }

  // Convert input to array for easier indexing
  let input_chars : Array[Char] = []
  for c in input {
    input_chars.push(c)
  }
  while in_pos < input_chars.length() {
    let oldi = i_val
    let mut w = 1
    let mut k = Base
    while true {
      if in_pos >= input_chars.length() {
        raise BadInput
      }
      let digit = decode_digit(input_chars[in_pos].to_int())
      in_pos = in_pos + 1
      if digit >= Base {
        raise BadInput
      }
      if digit > (0x7FFFFFFF - i_val) / w {
        raise Overflow
      }
      i_val = i_val + digit * w
      let t = if k <= bias {
        Tmin
      } else if k >= bias + Tmax {
        Tmax
      } else {
        k - bias
      }
      if digit < t {
        break
      }
      if w > 0x7FFFFFFF / (Base - t) {
        raise Overflow
      }
      w = w * (Base - t)
      k = k + Base
    }
    let out_len = output.length() + 1
    bias = adapt(i_val - oldi, out_len, oldi == 0)
    if i_val / out_len > 0x7FFFFFFF - n {
      raise Overflow
    }
    n = n + i_val / out_len
    i_val = i_val % out_len

    // Insert n at position i_val
    output.insert(i_val, n.unsafe_to_char())
    i_val = i_val + 1
  }

  // Convert characters to string
  chars_to_string(output)
}

///|
/// Convert array of characters to string
fn chars_to_string(chars : Array[Char]) -> String {
  let sb = StringBuilder::new()
  for c in chars {
    sb.write_char(c)
  }
  sb.to_string()
}
