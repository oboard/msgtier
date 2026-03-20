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
struct ForeignNetworkState {
  mut manager : ForeignNetworkManager
}

///|
let foreign_network_state : ForeignNetworkState = {
  manager: ForeignNetworkManager::new(),
}

///|
fn init_foreign_network_manager() -> Unit {
  let limit = get_config().foreign_relay_bps_limit.unwrap_or(0)
  foreign_network_state.manager = ForeignNetworkManager::new(
    relay_bps_limit=limit,
  )
  ignore(foreign_network_state.manager.relay_bps_limit)
}
