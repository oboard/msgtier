///|
struct Emitter {
  out : StringBuilder
}

///|
pub fn Emitter::new() -> Emitter {
  { out: StringBuilder() }
}

///|
pub fn Emitter::write(self : Emitter, source : String) -> Unit {
  self.out.write_string(source)
}

///|
pub fn Emitter::finish(self : Emitter) -> String {
  self.out.to_string()
}

///|
fn hex_digit(value : Int) -> String {
  match value {
    0 => "0"
    1 => "1"
    2 => "2"
    3 => "3"
    4 => "4"
    5 => "5"
    6 => "6"
    7 => "7"
    8 => "8"
    9 => "9"
    10 => "A"
    11 => "B"
    12 => "C"
    13 => "D"
    14 => "E"
    _ => "F"
  }
}

///|
fn hex_upper(value : Int) -> String {
  if value == 0 {
    return "0"
  }
  let mut n = value
  let mut result = ""
  while n > 0 {
    result = hex_digit(n % 16) + result
    n = n / 16
  }
  result
}

///|
fn hex_code(value : Int) -> String {
  let mut digits = hex_upper(value)
  while digits.length() < 4 {
    digits = "0" + digits
  }
  "0x" + digits
}

///|
pub fn Emitter::write_file_header(
  self : Emitter,
  title : String,
  generated_from : String,
) -> Unit {
  self.write("///|\n")
  self.write("/// " + title + "\n")
  self.write("/// Generated from " + generated_from + "\n\n")
}

///|
pub fn Emitter::write_int_array(
  self : Emitter,
  doc : String,
  name : String,
  values : Array[Int],
  hex~ : Bool,
) -> Unit {
  self.write("///|\n")
  self.write("/// " + doc + "\n")
  self.write("let " + name + " : FixedArray[Int] = [\n")
  for value in values {
    self.write("  ")
    if hex {
      self.write(hex_code(value))
    } else {
      self.write(value.to_string())
    }
    self.write(",\n")
  }
  self.write("]\n\n")
}
