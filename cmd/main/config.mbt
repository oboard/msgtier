///|
struct Config {
  name : String
  secret : String
  peers : Array[@url.Url]
  listeners : Array[@url.Url]
  scripts : Array[String]?
} derive(Show, ToJson, FromJson)

///|
async fn Config::from_file(path : String) -> Config {
  let json = @fs.read_file(path).json()
  let config = @json.from_json(json)
  config
}
