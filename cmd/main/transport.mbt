///|
pub trait Transport {
  async send(Self, String, Bytes) -> Bool
  async listen(
    Self,
    @async.TaskGroup[Unit],
    (Bytes, String) -> Unit,
    (String) -> Unit,
  ) -> Unit
  local_addr(Self) -> String
  protocol(Self) -> String
}
