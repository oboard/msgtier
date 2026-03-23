///|
struct HotReloadSettings {
  enable : Bool?
  secret : String?
} derive(Show, ToJson, FromJson)

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
  forwards : Map[String, String]?
  exposes : Map[String, String]?
  log : LogLevel?
  relay_network_whitelist : Array[String]?
  relay_all_peer_rpc : Bool?
  foreign_relay_bps_limit : Int?
  upload_dir : String?
  disable_encryption : Bool?
  hot_reload : HotReloadSettings?
} derive(Show, ToJson, FromJson)

///|
struct AppState {
  version : String
  mut config : Config?
  mut root : @async.TaskGroup[Unit]?
}

///|
let app_state : AppState = { version: "0.1.0", config: None, root: None }

///|
async fn Config::from_file(path : String) -> Config {
  @fs.read_file(path).text() |> @json5.parse |> @json.from_json
}

///|
fn Config::is_encrypt(self : Config) -> Bool {
  self.disable_encryption != Some(true)
}

///|
fn empty_config() -> Config {
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
    forwards: None,
    exposes: None,
    log: None,
    relay_network_whitelist: None,
    relay_all_peer_rpc: None,
    foreign_relay_bps_limit: None,
    upload_dir: None,
    disable_encryption: None,
    hot_reload: None,
  }
}

///|
fn Config::hot_reload_enabled(self : Config) -> Bool {
  match self.hot_reload {
    Some({ enable: Some(false), .. }) => false
    _ => true
  }
}

///|
fn Config::hot_reload_secret(self : Config) -> String? {
  match self.hot_reload {
    Some({ secret: Some(secret), .. }) if secret.trim() != "" => Some(secret)
    _ => None
  }
}

///|
fn get_config_static_json(config : Config) -> Json {
  {
    "id": config.id,
    "secret": config.secret,
    "peers": config.peers,
    "listeners": config.listeners,
    "web_api": config.web_api,
  }
}

///|
fn get_config_hot_json(config : Config) -> Json {
  {
    "scripts": config.scripts,
    "metadata": config.metadata,
    "openclaw": config.openclaw,
    "openclaw_plugin_version": config.openclaw_plugin_version,
    "openclaw_token": config.openclaw_token,
    "forwards": config.forwards,
    "exposes": config.exposes,
    "log": config.log,
    "relay_network_whitelist": config.relay_network_whitelist,
    "relay_all_peer_rpc": config.relay_all_peer_rpc,
    "foreign_relay_bps_limit": config.foreign_relay_bps_limit,
    "upload_dir": config.upload_dir,
    "disable_encryption": config.disable_encryption,
    "hot_reload": config.hot_reload,
  }
}

///|
fn get_config_response_json() -> Json {
  let config = get_config()
  {
    "id": config.id,
    "secret": config.secret,
    "peers": config.peers,
    "listeners": config.listeners,
    "scripts": config.scripts,
    "web_api": config.web_api,
    "metadata": config.metadata,
    "openclaw": config.openclaw,
    "openclaw_plugin_version": config.openclaw_plugin_version,
    "openclaw_token": config.openclaw_token,
    "forwards": config.forwards,
    "exposes": config.exposes,
    "log": config.log,
    "relay_network_whitelist": config.relay_network_whitelist,
    "relay_all_peer_rpc": config.relay_all_peer_rpc,
    "foreign_relay_bps_limit": config.foreign_relay_bps_limit,
    "upload_dir": config.upload_dir,
    "disable_encryption": config.disable_encryption,
    "hot_reload": config.hot_reload,
    "static_config": get_config_static_json(config),
    "hot_config": get_config_hot_json(config),
  }
}

///|
fn json_to_string_map(value : Json) -> Map[String, String]? {
  let parsed : Map[String, String] = @json.from_json(value) catch {
    _ => return None
  }
  Some(parsed)
}

///|
fn json_to_string_array(value : Json) -> Array[String]? {
  let parsed : Array[String] = @json.from_json(value) catch { _ => return None }
  Some(parsed)
}

///|
fn json_to_string(value : Json) -> String? {
  let parsed : String = @json.from_json(value) catch { _ => return None }
  Some(parsed)
}

///|
fn json_to_int(value : Json) -> Int? {
  let parsed : Int = @json.from_json(value) catch { _ => return None }
  Some(parsed)
}

///|
fn json_to_bool(value : Json) -> Bool? {
  let parsed : Bool = @json.from_json(value) catch { _ => return None }
  Some(parsed)
}

///|
fn json_to_log_level(value : Json) -> LogLevel? {
  let parsed : LogLevel = @json.from_json(value) catch { _ => return None }
  Some(parsed)
}

///|
fn json_to_hot_reload_settings(value : Json) -> HotReloadSettings? {
  let parsed : HotReloadSettings = @json.from_json(value) catch {
    _ => return None
  }
  Some(parsed)
}

///|
fn validate_hot_reload_patch_fields(obj : Map[String, Json]) -> String? {
  let static_fields = ["id", "secret", "peers", "listeners", "web_api", "port"]
  for key in static_fields {
    if obj.contains(key) {
      return Some("field `\{key}` cannot be hot reloaded")
    }
  }
  None
}

///|
fn apply_hot_reload_patch(
  config : Config,
  obj : Map[String, Json],
) -> Result[Config, String] {
  match validate_hot_reload_patch_fields(obj) {
    Some(err) => return Err(err)
    None => ()
  }

  let mut next = config
  for key, value in obj {
    match key {
      "scripts" =>
        if value is Null {
          next = { ..next, scripts: None }
        } else {
          match json_to_string_map(value) {
            Some(v) => next = { ..next, scripts: Some(v) }
            None => return Err("invalid `scripts` value")
          }
        }
      "metadata" =>
        if value is Null {
          next = { ..next, metadata: None }
        } else {
          match json_to_string_map(value) {
            Some(v) => next = { ..next, metadata: Some(v) }
            None => return Err("invalid `metadata` value")
          }
        }
      "openclaw" =>
        if value is Null {
          next = { ..next, openclaw: None }
        } else {
          match json_to_bool(value) {
            Some(v) => next = { ..next, openclaw: Some(v) }
            None => return Err("invalid `openclaw` value")
          }
        }
      "openclaw_plugin_version" =>
        if value is Null {
          next = { ..next, openclaw_plugin_version: None }
        } else {
          match json_to_string(value) {
            Some(v) => next = { ..next, openclaw_plugin_version: Some(v) }
            None => return Err("invalid `openclaw_plugin_version` value")
          }
        }
      "openclaw_token" =>
        if value is Null {
          next = { ..next, openclaw_token: None }
        } else {
          match json_to_string(value) {
            Some(v) => next = { ..next, openclaw_token: Some(v) }
            None => return Err("invalid `openclaw_token` value")
          }
        }
      "forwards" =>
        if value is Null {
          next = { ..next, forwards: None }
        } else {
          match json_to_string_map(value) {
            Some(v) => next = { ..next, forwards: Some(v) }
            None => return Err("invalid `forwards` value")
          }
        }
      "exposes" =>
        if value is Null {
          next = { ..next, exposes: None }
        } else {
          match json_to_string_map(value) {
            Some(v) => next = { ..next, exposes: Some(v) }
            None => return Err("invalid `exposes` value")
          }
        }
      "log" =>
        if value is Null {
          next = { ..next, log: None }
        } else {
          match json_to_log_level(value) {
            Some(v) => next = { ..next, log: Some(v) }
            None => return Err("invalid `log` value")
          }
        }
      "relay_network_whitelist" =>
        if value is Null {
          next = { ..next, relay_network_whitelist: None }
        } else {
          match json_to_string_array(value) {
            Some(v) => next = { ..next, relay_network_whitelist: Some(v) }
            None => return Err("invalid `relay_network_whitelist` value")
          }
        }
      "relay_all_peer_rpc" =>
        if value is Null {
          next = { ..next, relay_all_peer_rpc: None }
        } else {
          match json_to_bool(value) {
            Some(v) => next = { ..next, relay_all_peer_rpc: Some(v) }
            None => return Err("invalid `relay_all_peer_rpc` value")
          }
        }
      "foreign_relay_bps_limit" =>
        if value is Null {
          next = { ..next, foreign_relay_bps_limit: None }
        } else {
          match json_to_int(value) {
            Some(v) => next = { ..next, foreign_relay_bps_limit: Some(v) }
            None => return Err("invalid `foreign_relay_bps_limit` value")
          }
        }
      "upload_dir" =>
        if value is Null {
          next = { ..next, upload_dir: None }
        } else {
          match json_to_string(value) {
            Some(v) => next = { ..next, upload_dir: Some(v) }
            None => return Err("invalid `upload_dir` value")
          }
        }
      "disable_encryption" =>
        if value is Null {
          next = { ..next, disable_encryption: None }
        } else {
          match json_to_bool(value) {
            Some(v) => next = { ..next, disable_encryption: Some(v) }
            None => return Err("invalid `disable_encryption` value")
          }
        }
      "hot_reload" =>
        if value is Null {
          next = { ..next, hot_reload: None }
        } else {
          match json_to_hot_reload_settings(value) {
            Some(v) => next = { ..next, hot_reload: Some(v) }
            None => return Err("invalid `hot_reload` value")
          }
        }
      _ => return Err("unsupported hot reload field `\{key}`")
    }
  }
  Ok(next)
}

///|
fn set_config(config : Config) -> Unit {
  app_state.config = Some(config)
}

///|
fn ensure_hot_reload_allowed(
  config : Config,
  provided_secret : String?,
) -> String? {
  if !config.hot_reload_enabled() {
    return Some("hot reload is disabled")
  }
  match config.hot_reload_secret() {
    Some(expected) =>
      if provided_secret == Some(expected) {
        None
      } else {
        Some("invalid hot reload secret")
      }
    None => None
  }
}

///|
fn refresh_runtime_config(config : Config) -> Result[Config, String] {
  set_config(config)
  if app_state.root is Some(root) {
    refresh_port_forward_registry(root)
  }
  match config.listeners {
    [first, ..] => broadcast_sync(config.id, first)
    _ => ()
  }
  Ok(config)
}

///|
fn apply_hot_reload_request(body_str : String) -> Result[Config, String] {
  let parsed = @json.parse(body_str) catch {
    _ => return Err("invalid json payload")
  }
  let (provided_secret, patch_obj) = match parsed {
    Object(obj) =>
      match obj.get("config") {
        Some(Object(patch)) => {
          let provided_secret = match obj.get("secret") {
            Some(String(secret)) => Some(secret)
            _ => None
          }
          (provided_secret, patch)
        }
        _ => return Err("missing `config` object")
      }
    _ => return Err("request body must be a JSON object")
  }

  let current = get_config()
  match ensure_hot_reload_allowed(current, provided_secret) {
    Some(err) => return Err(err)
    None => ()
  }

  let next = match apply_hot_reload_patch(current, patch_obj) {
    Ok(config) => config
    Err(err) => return Err(err)
  }
  refresh_runtime_config(next)
}

///|
fn get_config() -> Config {
  match app_state.config {
    Some(config) => config
    None => empty_config()
  }
}
