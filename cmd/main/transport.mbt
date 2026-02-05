///|
pub trait Transport {
  async send(Self, String, Bytes) -> Bool
  async listen(Self, (Bytes, String) -> Unit) -> Unit
  local_addr(Self) -> String
  protocol(Self) -> String
}
