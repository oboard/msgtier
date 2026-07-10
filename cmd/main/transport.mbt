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

  ///|
  /// Send raw port-forward data, bypassing the message layer entirely.
  /// connection_id: the port-forward connection identifier
  /// seq: chunk sequence number (big-endian ordering)
  /// data: payload bytes
  /// Returns false if the transport does not support raw frames (caller should fall back to send_message).
  ///|
  async fn send_raw_port_forward(Self, String, String, Int, Bytes) -> Bool = _

  ///|
  /// Register a handler for raw port-forward data frames received on this transport.
  /// The handler receives (connection_id, seq, data).
  /// Transports that do not support raw frames may ignore this call.
  ///|
  fn set_raw_data_handler(Self, (String, Int, Bytes) -> Unit) -> Unit = _
}

///|
impl Transport with fn send_raw_port_forward(
  _self,
  _target,
  _connection_id,
  _seq,
  _data,
) {
  false
}

///|
impl Transport with fn set_raw_data_handler(_self, _handler) -> Unit {
  ()
}
