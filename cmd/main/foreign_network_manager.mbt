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
let global_foreign_network_manager : Ref[ForeignNetworkManager] = Ref::new(
  ForeignNetworkManager::new(),
)

///|
fn init_foreign_network_manager() -> Unit {
  let limit = get_config().foreign_relay_bps_limit.unwrap_or(0)
  global_foreign_network_manager.val = ForeignNetworkManager::new(
    relay_bps_limit=limit,
  )
}
