///|
pub trait Transport {
  ///|
  /// Send a message to the specified address.
  ///|
  async fn send(Self, String, Bytes) -> Bool

  ///|
  /// Listen for incoming messages.
  ///|
  async fn listen(
    Self,
    @async.TaskGroup[Unit],
    (Bytes, String) -> Unit,
    (String) -> Unit,
  ) -> Unit
  fn local_addr(Self) -> String
  fn protocol(Self) -> String

  ///|
  /// Get the protocol type as a typed enum.
  ///|
  fn protocol_type(Self) -> Protocol

  ///|
  /// Get the local address as a typed Address.
  ///|
  fn local_address(Self) -> Address
}
