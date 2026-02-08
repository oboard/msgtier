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
} derive(Show, ToJson, FromJson)

///|
async fn Config::from_file(path : String) -> Config {
  @fs.read_file(path).text() |> @json5.parse |> @json.from_json
}

///|
fn get_config() -> Config {
  match global_config.val {
    Some(config) => config
    None => abort("Missing config")
  }
}
