// Test utility functions

// Helper function: create byte array

///|
pub fn bytes(values : Array[Int]) -> Bytes {
  let byte_array : Array[Byte] = []
  for value in values {
    byte_array.push(value.to_byte())
  }
  Bytes::from_array(byte_array)
}

// Helper function: compare byte arrays

///|
pub fn bytes_equal(a : Bytes, b : Bytes) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i = 0; i < a.length(); i = i + 1 {
    if a[i] != b[i] {
      return false
    }
  }
  true
}
