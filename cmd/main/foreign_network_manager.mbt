///|
struct ForeignNetworkPacket {
  target_network : String
  target_peer_id : String
  payload : Bytes
} derive(Show, ToJson, FromJson)

///|
struct ForeignNetworkManager {
  relay_bps_limit : Int
} derive(Show)

///|
fn ForeignNetworkManager::new(relay_bps_limit? : Int) -> ForeignNetworkManager {
  { relay_bps_limit: relay_bps_limit.unwrap_or(0) }
}

///|
pub fn ForeignNetworkManager::wrap_packet(
  _self : ForeignNetworkManager,
  target_network : String,
  target_peer_id : String,
  payload : Bytes,
) -> ForeignNetworkPacket {
  { target_network, target_peer_id, payload }
}

///|
pub fn ForeignNetworkManager::unwrap_packet(
  _self : ForeignNetworkManager,
  packet : ForeignNetworkPacket,
) -> (String, String, Bytes) {
  (packet.target_network, packet.target_peer_id, packet.payload)
}

///|
let global_foreign_network_manager : Ref[ForeignNetworkManager] = Ref::new(
  ForeignNetworkManager::new(),
)

///|
pub fn get_global_foreign_network_manager() -> ForeignNetworkManager {
  global_foreign_network_manager.val
}

///|
fn init_foreign_network_manager(config : Config) -> Unit {
  let limit = config.foreign_relay_bps_limit.unwrap_or(0)
  global_foreign_network_manager.val = ForeignNetworkManager::new(
    relay_bps_limit=limit,
  )
}
