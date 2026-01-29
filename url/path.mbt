///|
enum Path {
  Opaque(String)
  Segments(Array[String])
}

///|
/// Serialize path per WHATWG URL spec
fn Path::to_string(self : Path) -> String {
  match self {
    Opaque(path) => path
    Segments(segments) =>
      if segments.is_empty() {
        ""
      } else {
        "/" + segments.iter().map(fn(s) { s }).join("/")
      }
  }
}

///|
/// Shorten path per WHATWG URL spec
/// For file URLs, don't shorten past Windows drive letter
fn Path::shorten(self : Path, scheme? : String = "") -> Unit {
  match self {
    Opaque(_) => ()
    Segments(segments) => {
      // Per WHATWG: If scheme is "file", path has 1 element, and it's a Windows drive letter, don't shorten
      if scheme == "file" && segments.length() == 1 {
        match segments.get(0) {
          Some(first) if first.length() == 2 =>
            match first {
              [letter, ':'] if letter.is_ascii_alphabetic() => return
              _ => ()
            }
          _ => ()
        }
      }
      if !segments.is_empty() {
        segments.pop() |> ignore()
      }
    }
  }
}

///|
/// Create a deep copy of the path
fn Path::clone(self : Path) -> Path {
  match self {
    Opaque(s) => Opaque(s)
    Segments(segments) => Segments(segments.copy())
  }
}
