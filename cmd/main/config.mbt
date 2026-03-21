///|
struct Config {
  id : String
  secret : String
  peers : Array[String]
  listeners : Array[String]
  scripts : Map[String, String]?
  web_api : String?
  metadata : Map[String, String]?
  openclaw : Bool?
  openclaw_plugin_version : String?
  openclaw_token : String?
  port_forward_exposes : Array[PortForwardExposeRule]?
  port_forward_forwards : Array[PortForwardForwardRule]?
  log : LogLevel?
  port : Map[String, String]?
  relay_network_whitelist : Array[String]?
  relay_all_peer_rpc : Bool?
  foreign_relay_bps_limit : Int?
  upload_dir : String?
  disable_encryption : Bool?
} derive(Show, ToJson, FromJson)

///|
struct AppState {
  version : String
  mut config : Config?
}

///|
let app_state : AppState = { version: "0.1.0", config: None }

///|
async fn Config::from_file(path : String) -> Config {
  @fs.read_file(path).text() |> @json5.parse |> @json.from_json
}

///|
fn Config::is_encrypt(self : Config) -> Bool {
  self.disable_encryption != Some(true)
}

///|
fn get_config() -> Config {
  match app_state.config {
    Some(config) => config
    None =>
      {
        id: "",
        secret: "",
        peers: [],
        listeners: [],
        scripts: None,
        web_api: None,
        metadata: None,
        openclaw: None,
        openclaw_plugin_version: None,
        openclaw_token: None,
        port_forward_exposes: None,
        port_forward_forwards: None,
        log: None,
        port: None,
        relay_network_whitelist: None,
        relay_all_peer_rpc: None,
        foreign_relay_bps_limit: None,
        upload_dir: None,
        disable_encryption: None,
      }
  }
}
