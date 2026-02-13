///|
#external
priv type Handler

///|
extern "C" fn list_interfaces_ffi() -> Handler = "loip_list_interfaces_ffi"

///|
fn handler_to_fixed_array(handler : Handler) -> FixedArray[Bytes] = "%identity"

///|
pub struct Interface {
  name : String
  ipv4 : Array[String]
  ipv6 : Array[String]
  is_up : Bool
  kind : InterfaceKind
} derive(Show, Debug, Eq)

///|
pub enum InterfaceKind {
  Physical
  Virtual
  Loopback
} derive(Show, Debug, Eq)

///|
fn parse_line(line : String) -> (String, String, Bool, InterfaceKind) {
  let parts = line.split(" ").collect()
  let filtered : Array[String] = []
  for part in parts {
    if !part.is_empty() {
      filtered.push(part.to_string())
    }
  }
  match filtered {
    [name, ip, status, kind, ..] => {
      let is_up = status == "UP"
      let kind = match kind {
        "Physical" => Physical
        "Virtual" => Virtual
        "Loopback" => Loopback
        _ => Physical
      }
      (name, ip, is_up, kind)
    }
    _ => ("", "", false, Physical)
  }
}

///|
fn decode_interfaces(
  handler : Handler,
) -> Array[(String, String, Bool, InterfaceKind)] {
  let lines = Array::from_fixed_array(handler_to_fixed_array(handler))
  let decoded = lines.map(x => @utf8.decode(x) catch { _ => "" })
  decoded.map(parse_line)
}

///|
pub fn list_interfaces() -> Array[Interface] {
  let results : Array[Interface] = []
  let all = decode_interfaces(list_interfaces_ffi())

  for item in all {
    let (name, ip, is_up, kind) = item
    if name.length() == 0 || ip.length() == 0 {
      continue
    }
    let mut found = false
    for i = 0; i < results.length(); i = i + 1 {
      if results[i].name == name {
        found = true
        if ip.contains(":") {
          results[i].ipv6.push(ip)
        } else {
          results[i].ipv4.push(ip)
        }
        break
      }
    }
    if !found {
      let ipv4_list : Array[String] = []
      let ipv6_list : Array[String] = []
      if ip.contains(":") {
        ipv6_list.push(ip)
      } else {
        ipv4_list.push(ip)
      }
      results.push({ name, ipv4: ipv4_list, ipv6: ipv6_list, is_up, kind })
    }
  }
  results
}
