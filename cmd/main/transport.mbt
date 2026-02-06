///|
pub trait Transport {
  ///|
  /// Send a message to the specified address.
  ///|
  async send(Self, String, Bytes) -> Bool

  ///|
  /// Listen for incoming messages.
  ///|
  async listen(
    Self,
    @async.TaskGroup[Unit],
    (Bytes, String) -> Unit,
    (String) -> Unit,
  ) -> Unit
  local_addr(Self) -> String
  protocol(Self) -> String
}
