///|
pub fn slice(bytes : Bytes, start : Int, len : Int) -> Bytes {
  let res = FixedArray::make(len, b'\x00')
  for i = 0; i < len; i = i + 1 {
    res[i] = bytes[start + i]
  }
  Bytes::from_array(res)
}
