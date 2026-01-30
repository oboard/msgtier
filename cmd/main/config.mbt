///|
struct Config {
  id : String
  secret : String
  peers : Array[@url.Url]
  listeners : Array[@url.Url]
  scripts : Map[String, String]?
  web_api : String?
} derive(Show, ToJson, FromJson)

///|
async fn Config::from_file(path : String) -> Config {
  let json = @fs.read_file(path).json()
  let config = @json.from_json(json)
  config
}
