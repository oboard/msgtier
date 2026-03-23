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
  if validate_hot_reload_patch_fields(obj) is Some(err) {
    return Err(err)
  }

  let mut next = config
  for key, value in obj {
    match key {
      "scripts" =>
        if @jsonx.nul(value) is Some(v) {
          next = { ..next, scripts: v }
        } else {
          return Err("invalid `scripts` value")
        }
      "metadata" =>
        if @jsonx.nul(value) is Some(v) {
          next = { ..next, metadata: v }
        } else {
          return Err("invalid `metadata` value")
        }
      "openclaw" =>
        if @jsonx.nul(value) is Some(v) {
          next = { ..next, openclaw: v }
        } else {
          return Err("invalid `openclaw` value")
        }
      "openclaw_plugin_version" =>
        if @jsonx.nul(value) is Some(v) {
          next = { ..next, openclaw_plugin_version: v }
        } else {
          return Err("invalid `openclaw_plugin_version` value")
        }
      "openclaw_token" =>
        if @jsonx.nul(value) is Some(v) {
          next = { ..next, openclaw_token: v }
        } else {
          return Err("invalid `openclaw_token` value")
        }
      "forwards" =>
        if @jsonx.nul(value) is Some(v) {
          next = { ..next, forwards: v }
        } else {
          return Err("invalid `forwards` value")
        }
      "exposes" =>
        if @jsonx.nul(value) is Some(v) {
          next = { ..next, exposes: v }
        } else {
          return Err("invalid `exposes` value")
        }
      "log" =>
        if @jsonx.nul(value) is Some(v) {
          next = { ..next, log: v }
        } else {
          return Err("invalid `log` value")
        }
      "relay_network_whitelist" =>
        if @jsonx.nul(value) is Some(v) {
          next = { ..next, relay_network_whitelist: v }
        } else {
          return Err("invalid `relay_network_whitelist` value")
        }
      "relay_all_peer_rpc" =>
        if @jsonx.nul(value) is Some(v) {
          next = { ..next, relay_all_peer_rpc: v }
        } else {
          return Err("invalid `relay_all_peer_rpc` value")
        }
      "foreign_relay_bps_limit" =>
        if @jsonx.nul(value) is Some(v) {
          next = { ..next, foreign_relay_bps_limit: v }
        } else {
          return Err("invalid `foreign_relay_bps_limit` value")
        }
      "upload_dir" =>
        if @jsonx.nul(value) is Some(v) {
          next = { ..next, upload_dir: v }
        } else {
          return Err("invalid `upload_dir` value")
        }
      "disable_encryption" =>
        if @jsonx.nul(value) is Some(v) {
          next = { ..next, disable_encryption: v }
        } else {
          return Err("invalid `disable_encryption` value")
        }
      "hot_reload" =>
        if @jsonx.nul(value) is Some(v) {
          next = { ..next, hot_reload: v }
        } else {
          return Err("invalid `hot_reload` value")
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
  if config.hot_reload_secret() is Some(expected) {
    if provided_secret == Some(expected) {
      None
    } else {
      Some("invalid hot reload secret")
    }
  } else {
    None
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
