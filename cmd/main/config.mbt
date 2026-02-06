///|
struct Config {
  id : String
  secret : String
  peers : Array[@url.Url]
  listeners : Array[@url.Url]
  scripts : Map[String, String]?
  web_api : String?
  metadata : Map[String, String]?
} derive(Show, ToJson, FromJson)

///|
async fn Config::from_file(path : String) -> Config {
  @fs.read_file(path).text() |> @json5.parse |> @json.from_json
}
