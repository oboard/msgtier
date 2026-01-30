///|
/// Global state for the peer manager using new architecture
let global_peer_manager : Ref[PeerManager] = Ref::new(PeerManager::new())

///|
/// Update global peer manager state
pub fn update_global_peer_manager(
  fn_update : (PeerManager) -> PeerManager,
) -> Unit {
  let current = global_peer_manager.val
  let updated = fn_update(current)
  global_peer_manager.val = updated
}

///|
/// Update global reconnect manager state
pub fn update_global_reconnect_manager(
  fn_update : (ReconnectManager) -> ReconnectManager,
) -> Unit {
  let current = global_reconnect_manager.val
  let updated = fn_update(current)
  global_reconnect_manager.val = updated
}

///|
/// Get current global peer manager
pub fn get_global_peer_manager() -> PeerManager {
  global_peer_manager.val
}

///|
/// Get current global reconnect manager
pub fn get_global_reconnect_manager() -> ReconnectManager {
  global_reconnect_manager.val
}
