///|
/// Debug utility to diagnose msgpack decode errors
fn diagnose_msgpack_error(data : Bytes) -> Unit {
  if data.length() == 0 {
    println("DEBUG: Received empty message")
    return
  }
  let first_byte = data.at(0).to_int()
  println(
    "DEBUG: Message decode error - first byte: 0x\{bytes_to_hex(Bytes::from_array([data.at(0)]))}, length: \{data.length()}",
  )

  // Check if it looks like msgpack
  if first_byte >= 0xa0 && first_byte <= 0xbf {
    // fixstr format
    let str_len = first_byte - 0xa0
    println("DEBUG: Appears to be fixstr with length \{str_len}")
  } else if first_byte >= 0x90 && first_byte <= 0x9f {
    // fixarray format
    let arr_len = first_byte - 0x90
    println("DEBUG: Appears to be fixarray with length \{arr_len}")
  } else if first_byte >= 0x80 && first_byte <= 0x8f {
    // fixmap format
    let map_len = first_byte - 0x80
    println("DEBUG: Appears to be fixmap with \{map_len} entries")
  } else if first_byte == 0xdc {
    println("DEBUG: Appears to be array16")
  } else if first_byte == 0xdd {
    println("DEBUG: Appears to be array32")
  } else if first_byte == 0xde {
    println("DEBUG: Appears to be map16")
  } else if first_byte == 0xdf {
    println("DEBUG: Appears to be map32")
  } else {
    let preview_len = data.length().min(20)
    let preview = data[:preview_len]
    println(
      "DEBUG: Unknown msgpack format or corrupted data - first \{preview_len} bytes: \{bytes_to_hex(preview.to_bytes())}",
    )
  }
}
