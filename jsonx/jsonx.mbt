///|
pub fn[T : @json.FromJson] opt(value : Json) -> T? {
  Some(@json.from_json(value)) catch {
    _ => None
  }
}

///|
pub fn[T : @json.FromJson] nul(value : Json) -> T?? {
  if value is Null {
    Some(None)
  } else {
    let parsed : T? = opt(value)
    if parsed is Some(v) {
      Some(Some(v))
    } else {
      None
    }
  }
}

///|
pub fn[T : @json.FromJson] get(obj : Map[String, Json], key : String) -> T? {
  if obj.get(key) is Some(value) {
    let parsed : T? = opt(value)
    parsed
  } else {
    None
  }
}

///|
pub fn sub(obj : Map[String, Json], key : String) -> Map[String, Json]? {
  if obj.get(key) is Some(Object(child)) {
    Some(child)
  } else {
    None
  }
}

///|
pub fn str(value : Json) -> String? {
  if value is String(v) {
    Some(v)
  } else if value is Number(v, ..) {
    Some(v.to_int().to_string())
  } else {
    None
  }
}

///|
pub fn strf(obj : Map[String, Json], key : String) -> String? {
  if obj.get(key) is Some(value) {
    str(value)
  } else {
    None
  }
}

///|
pub fn int(value : Json) -> Int? {
  if value is Number(v, ..) {
    Some(v.to_int())
  } else if value is String(v) {
    (try? @strconv.parse_int(v)).to_option()
  } else {
    None
  }
}

///|
pub fn intf(obj : Map[String, Json], key : String) -> Int? {
  if obj.get(key) is Some(value) {
    int(value)
  } else {
    None
  }
}

///|
pub fn strs(obj : Map[String, Json], path : Array[String]) -> String? {
  guard !path.is_empty() else { None }
  let mut current = obj
  let last = path.length() - 1
  let mut i = 0
  while i < last {
    guard sub(current, path[i]) is Some(next) else { return None }
    current = next
    i = i + 1
  }
  strf(current, path[last])
}
