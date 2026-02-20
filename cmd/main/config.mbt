///|
struct Config {
  id : String
  secret : String
  peers : Array[String]
  listeners : Array[String]
  scripts : Map[String, String]?
  web_api : String?
  metadata : Map[String, String]?
  log : LogLevel?
  port : Map[String, String]?
  relay_network_whitelist : Array[String]?
  relay_all_peer_rpc : Bool?
  foreign_relay_bps_limit : Int?
  upload_dir : String?
} derive(Show, ToJson, FromJson)

///|
async fn Config::from_file(path : String) -> Config {
  @fs.read_file(path).text() |> @json5.parse |> @json.from_json
}

///|
fn get_config() -> Config {
  match global_config.val {
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
        log: None,
        port: None,
        relay_network_whitelist: None,
        relay_all_peer_rpc: None,
        foreign_relay_bps_limit: None,
        upload_dir: None,
      }
  }
}
