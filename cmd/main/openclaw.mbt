///|
struct OpenClawRuntimeInstance {
  id : String
  channel_id : String
  channel_type : String
  label : String
  platform : String
  agent_id : String
  api : String
  state : String
  gateway_port : Int
  base_url : String
  auth_mode : String
  token : String?
  password : String?
  executable_path : String?
  state_dir : String?
  profile : String?
} derive(Show, Eq)

///|
struct OpenClawPublicInstance {
  id : String
  label : String
  platform : String
  agent_id : String
  api : String
  state : String
  gateway_port : Int
} derive(Show, Eq)

///|
struct ChannelInstance {
  id : String
  type_ : String
  label : String
  state : String
  meta : Json
} derive(Show, Eq)

///|
struct OpenClawState {
  mut runtimes : Array[OpenClawRuntimeInstance]
}

///|
let openclaw_state : OpenClawState = { runtimes: [] }

///|
let msgtier_openclaw_plugin_id = "msgtier"

///|
fn openclaw_channel_target_id(peer_id : String, channel_id : String) -> String {
  "channel::" + peer_id + "::" + channel_id
}

///|
fn is_windows_platform() -> Bool {
  match @sys.get_env_var("OS") {
    Some(os_name) => os_name.contains("Windows")
    None => false
  }
}

///|
fn user_home_dir() -> String {
  let env_name = if is_windows_platform() { "USERPROFILE" } else { "HOME" }
  match @sys.get_env_var(env_name) {
    Some(v) => v
    None => @env.current_dir().unwrap_or(".")
  }
}

///|
async fn run_command_capture(program : String, args : Array[String]) -> String? {
  let (stdout_r, stdout_w) = @pipe.pipe() catch { _ => return None }
  let exit_code = @process.run(program, args, stdout=stdout_w) catch {
    _ => {
      stdout_w.close()
      stdout_r.close()
      return None
    }
  }
  stdout_w.close()
  let output = stdout_r.read_all().text() catch {
      _ => {
        stdout_r.close()
        return None
      }
    }
  stdout_r.close()
  if exit_code == 0 {
    Some(output)
  } else {
    None
  }
}

///|
async fn run_command_capture_status(
  program : String,
  args : Array[String],
) -> (Int, String)? {
  let (stdout_r, stdout_w) = @pipe.pipe() catch { _ => return None }
  let exit_code = @process.run(program, args, stdout=stdout_w) catch {
    _ => {
      stdout_w.close()
      stdout_r.close()
      return None
    }
  }
  stdout_w.close()
  let output = stdout_r.read_all().text() catch {
      _ => {
        stdout_r.close()
        return None
      }
    }
  stdout_r.close()
  Some((exit_code, output))
}

///|
async fn run_shell_capture(command : String) -> (Int, String)? {
  if is_windows_platform() {
    run_command_capture_status("cmd", ["/C", command])
  } else {
    run_command_capture_status("zsh", ["-lc", command])
  }
}

///|
async fn file_exists(path : String) -> Bool {
  @fs.exists(path) catch {
    _ => false
  }
}

///|
async fn platform_name() -> String {
  if is_windows_platform() {
    return "windows"
  }
  match run_command_capture("uname", ["-s"]) {
    Some(output) =>
      if output.to_lower().contains("darwin") {
        "macos"
      } else {
        "linux"
      }
    None => "linux"
  }
}

///|
fn default_openclaw_state_dir() -> String {
  if is_windows_platform() {
    user_home_dir() + "\\.openclaw"
  } else {
    user_home_dir() + "/.openclaw"
  }
}

///|
fn path_join(base : String, child : String) -> String {
  if is_windows_platform() {
    base + "\\" + child
  } else {
    base + "/" + child
  }
}

///|
fn openclaw_auto_manage_enabled() -> Bool {
  match app_state.config {
    Some(config) => config.openclaw == Some(true)
    None => false
  }
}

///|
fn msgtier_openclaw_plugin_version() -> String {
  match app_state.config {
    Some(config) =>
      match config.openclaw_plugin_version {
        Some(version) => if version == "" { app_state.version } else { version }
        None => app_state.version
      }
    None => app_state.version
  }
}

///|
fn msgtier_openclaw_package_json() -> String {
  [
    "{",
    "  \"name\": \"msgtier\",",
    "  \"version\": \"" + msgtier_openclaw_plugin_version() + "\",",
    "  \"description\": \"MsgTier bridge plugin for OpenClaw\",",
    "  \"type\": \"module\",",
    "  \"openclaw\": {",
    "    \"extensions\": [\"./index.js\"]",
    "  }",
    "}",
  ].join("\n")
}

///|
fn msgtier_openclaw_plugin_manifest_json() -> String {
  [
    "{", "  \"id\": \"msgtier\",", "  \"configSchema\": {", "    \"type\": \"object\",",
    "    \"additionalProperties\": false,", "    \"properties\": {}", "  }", "}",
  ].join("\n")
}

///|
fn msgtier_openclaw_index_js() -> String {
  [
    "import { emptyPluginConfigSchema } from \"openclaw/plugin-sdk\";", "", "const plugin = {",
    "  id: \"msgtier\",", "  name: \"MsgTier\",", "  description: \"MsgTier bridge plugin\",",
    "  configSchema: emptyPluginConfigSchema(),", "  register() {},", "};", "", "export default plugin;",
  ].join("\n")
}

///|
fn openclaw_extensions_dir(state_dir : String) -> String {
  path_join(state_dir, "extensions")
}

///|
fn msgtier_managed_plugin_root(state_dir : String) -> String {
  path_join(state_dir, "managed-plugins")
}

///|
fn msgtier_managed_plugin_source_dir(state_dir : String) -> String {
  path_join(msgtier_managed_plugin_root(state_dir), "msgtier-src")
}

///|
fn msgtier_installed_plugin_dir(state_dir : String) -> String {
  path_join(openclaw_extensions_dir(state_dir), msgtier_openclaw_plugin_id)
}

///|
fn openclaw_config_path(state_dir : String) -> String {
  path_join(state_dir, "openclaw.json")
}

///|
async fn ensure_dir_exists(path : String) -> Unit {
  @fs.mkdir(path, permission=0o755) catch {
    _ => ()
  }
}

///|
async fn write_text_file_if_changed(path : String, contents : String) -> Bool {
  let existing = @fs.read_file(path).text() catch { _ => "" }
  if existing == contents {
    false
  } else {
    @fs.write_file(path, @utf8.encode(contents), create=0o644) catch {
      _ => return false
    }
    true
  }
}

///|
async fn ensure_msgtier_openclaw_plugin_files(plugin_dir : String) -> Bool {
  let parent_dir = match find_last_path_sep(plugin_dir) {
    Some(pos) => plugin_dir[:pos].to_string()
    None => ""
  }
  if parent_dir != "" {
    ensure_dir_exists(parent_dir)
  }
  ensure_dir_exists(plugin_dir)
  let mut changed = false
  changed = write_text_file_if_changed(
      path_join(plugin_dir, "package.json"),
      msgtier_openclaw_package_json(),
    ) ||
    changed
  changed = write_text_file_if_changed(
      path_join(plugin_dir, "openclaw.plugin.json"),
      msgtier_openclaw_plugin_manifest_json(),
    ) ||
    changed
  changed = write_text_file_if_changed(
      path_join(plugin_dir, "index.js"),
      msgtier_openclaw_index_js(),
    ) ||
    changed
  changed
}

///|
fn find_last_path_sep(path : String) -> Int? {
  let mut idx = path.length()
  while idx > 0 {
    idx = idx - 1
    let ch = path[idx]
    if ch == '/' || ch == '\\' {
      return Some(idx)
    }
  }
  None
}

///|
async fn ensure_msgtier_openclaw_plugin_source_files(
  state_dir : String,
) -> Bool {
  ensure_dir_exists(state_dir)
  ensure_dir_exists(msgtier_managed_plugin_root(state_dir))
  ensure_msgtier_openclaw_plugin_files(
    msgtier_managed_plugin_source_dir(state_dir),
  )
}

///|
async fn discover_openclaw_agent_ids(state_dir : String) -> Array[String] {
  let ids : Array[String] = []
  let seen : Map[String, Bool] = {}
  let agents_dir = path_join(state_dir, "agents")
  let entries = @fs.readdir(agents_dir, sort=true) catch { _ => [] }
  for entry in entries {
    if entry == "" || entry.has_prefix(".") {
      continue
    }
    if !seen.contains(entry) {
      seen[entry] = true
      ids.push(entry)
    }
  }
  let configured = resolve_agent_id(None)
  for fallback in [configured, "main"] {
    if !seen.contains(fallback) {
      seen[fallback] = true
      ids.push(fallback)
    }
  }
  ids
}

///|
async fn set_openclaw_plugin_config_state(
  state_dir : String,
  plugin_id : String,
  allow_enabled : Bool,
  entry_enabled : Bool?,
) -> Bool {
  let config_path = openclaw_config_path(state_dir)
  match parse_json_file_map(config_path) {
    Some(root) => {
      let plugins = match root.get("plugins") {
        Some(Object(obj)) => obj
        _ => {}
      }
      let allow_items = match plugins.get("allow") {
        Some(Array(items)) => items
        _ => []
      }
      let next_allow : Array[Json] = []
      let mut allow_found = false
      for item in allow_items {
        if item is String(existing) && existing == plugin_id {
          allow_found = true
          continue
        }
        next_allow.push(item)
      }
      if allow_enabled {
        next_allow.push(plugin_id.to_json())
      }
      let entries = match plugins.get("entries") {
        Some(Object(obj)) => obj
        _ => {}
      }
      let next_entries = entries.copy()
      let mut entry_changed = false
      match entry_enabled {
        Some(enabled) => {
          let next_entry = { "enabled": enabled }.to_json()
          match next_entries.get(plugin_id) {
            Some(existing) =>
              if existing != next_entry {
                next_entries[plugin_id] = next_entry
                entry_changed = true
              }
            None => {
              next_entries[plugin_id] = next_entry
              entry_changed = true
            }
          }
        }
        None =>
          if next_entries.contains(plugin_id) {
            next_entries.remove(plugin_id)
            entry_changed = true
          }
      }
      let allow_changed = allow_found != allow_enabled ||
        next_allow.length() != allow_items.length()
      if !allow_changed && !entry_changed {
        return false
      }
      let next_plugins = plugins.copy()
      next_plugins["allow"] = next_allow.to_json()
      next_plugins["entries"] = next_entries.to_json()
      let next_root = root.copy()
      next_root["plugins"] = next_plugins.to_json()
      @fs.write_file(
        config_path,
        @utf8.encode(next_root.to_json().stringify(indent=2)),
        create=0o600,
      ) catch {
        _ => return false
      }
      true
    }
    None => false
  }
}

///|
async fn remove_openclaw_plugin_config_refs(
  state_dir : String,
  plugin_id : String,
) -> Bool {
  set_openclaw_plugin_config_state(state_dir, plugin_id, false, None)
}

///|
async fn ensure_openclaw_plugin_enabled_and_allowed(
  state_dir : String,
  plugin_id : String,
) -> Bool {
  set_openclaw_plugin_config_state(state_dir, plugin_id, true, Some(true))
}

///|
fn shell_quote(path : String) -> String {
  if is_windows_platform() {
    "\"" + path.replace(old="\"", new="\"\"") + "\""
  } else {
    "'" + path.replace(old="'", new="'\"'\"'") + "'"
  }
}

///|
async fn remove_path_recursive(path : String) -> Bool {
  if !file_exists(path) {
    return false
  }
  let cmd = if is_windows_platform() {
    "rmdir /S /Q " + shell_quote(path)
  } else {
    "rm -rf " + shell_quote(path)
  }
  match run_shell_capture(cmd + " 2>&1") {
    Some((exit_code, _)) => exit_code == 0
    None => false
  }
}

///|
async fn install_openclaw_plugin_link(source_dir : String) -> Bool {
  let cmd = "openclaw plugins install --link " +
    shell_quote(source_dir) +
    " 2>&1"
  match run_shell_capture(cmd) {
    Some((exit_code, _)) => exit_code == 0
    None => false
  }
}

///|
async fn openclaw_plugin_needs_provenance_migration(plugin_id : String) -> Bool {
  let cmd = "openclaw plugins info " + plugin_id + " 2>&1"
  match run_shell_capture(cmd) {
    Some((_, output)) => output.contains("without install/load-path provenance")
    None => true
  }
}

///|
async fn ensure_openclaw_plugin_install_record(
  state_dir : String,
  plugin_id : String,
) -> Bool {
  let install_dir = msgtier_installed_plugin_dir(state_dir)
  let source_dir = msgtier_managed_plugin_source_dir(state_dir)
  if !openclaw_plugin_needs_provenance_migration(plugin_id) {
    return false
  }
  let mut changed = false
  changed = remove_openclaw_plugin_config_refs(state_dir, plugin_id) || changed
  changed = remove_path_recursive(install_dir) || changed
  changed = install_openclaw_plugin_link(source_dir) || changed
  changed
}

///|
async fn restart_openclaw_gateway_service() -> Bool {
  match run_command_capture("openclaw", ["gateway", "restart"]) {
    Some(_) => true
    None => false
  }
}

///|
async fn ensure_managed_openclaw_plugin() -> Unit {
  if !openclaw_auto_manage_enabled() {
    return
  }
  let state_dir = default_openclaw_state_dir()
  let files_changed = ensure_msgtier_openclaw_plugin_source_files(state_dir)
  let installed = ensure_openclaw_plugin_install_record(
    state_dir, msgtier_openclaw_plugin_id,
  )
  let enabled_or_allowed = ensure_openclaw_plugin_enabled_and_allowed(
    state_dir, msgtier_openclaw_plugin_id,
  )
  if files_changed || installed || enabled_or_allowed {
    if restart_openclaw_gateway_service() {
      log_info("Restarted OpenClaw gateway after ensuring MsgTier plugin")
    } else {
      log_warn(
        "Failed to restart OpenClaw gateway after ensuring MsgTier plugin",
      )
    }
  }
}

///|
fn candidate_executable_paths(platform : String) -> Array[String] {
  let paths : Array[String] = []
  if platform == "macos" {
    paths.push("/opt/homebrew/bin/openclaw")
    paths.push("/usr/local/bin/openclaw")
    paths.push("/Applications/OpenClaw.app/Contents/MacOS/openclaw")
  } else if platform == "linux" {
    paths.push("/usr/bin/openclaw")
    paths.push("/usr/local/bin/openclaw")
    paths.push("/snap/bin/openclaw")
    paths.push("/opt/openclaw/openclaw")
  } else {
    match @sys.get_env_var("ProgramFiles") {
      Some(v) => paths.push(v + "\\OpenClaw\\openclaw.exe")
      None => ()
    }
    match @sys.get_env_var("ProgramFiles(x86)") {
      Some(v) => paths.push(v + "\\OpenClaw\\OpenClaw.exe")
      None => ()
    }
    match @sys.get_env_var("LocalAppData") {
      Some(v) => paths.push(v + "\\Programs\\OpenClaw\\openclaw.exe")
      None => ()
    }
  }
  paths
}

///|
async fn find_executable_candidates(platform : String) -> Array[String] {
  let out : Array[String] = []
  let seen : Map[String, Bool] = {}
  let command_output = if platform == "windows" {
    run_command_capture("where", ["openclaw"])
  } else {
    run_command_capture("which", ["-a", "openclaw"])
  }
  match command_output {
    Some(paths) =>
      for line in paths.split("\n") {
        let path = line.trim().to_string()
        if path != "" && !seen.contains(path) {
          seen[path] = true
          out.push(path)
        }
      }
    None => ()
  }
  for path in candidate_executable_paths(platform) {
    if !seen.contains(path) && file_exists(path) {
      seen[path] = true
      out.push(path)
    }
  }
  out
}

///|
fn candidate_state_dirs() -> Array[String] {
  let dirs : Array[String] = []
  let seen : Map[String, Bool] = {}
  for env_name in ["OPENCLAW_STATE_DIR", "OPENCLAW_HOME"] {
    match @sys.get_env_var(env_name) {
      Some(dir) =>
        if dir != "" && !seen.contains(dir) {
          seen[dir] = true
          dirs.push(dir)
        }
      None => ()
    }
  }
  let fallback = default_openclaw_state_dir()
  if !seen.contains(fallback) {
    dirs.push(fallback)
  }
  dirs
}

///|
async fn parse_json_file_map(path : String) -> Map[String, Json]? {
  if !file_exists(path) {
    return None
  }
  let text = @fs.read_file(path).text() catch { _ => return None }
  let parsed = @json5.parse(text) catch {
    _ => @json.parse(text) catch { _ => return None }
  }
  match parsed {
    Object(map) => Some(map)
    _ => None
  }
}

///|
async fn read_state_dir_config(state_dir : String) -> Map[String, Json]? {
  let env_config_path = @sys.get_env_var("OPENCLAW_CONFIG_PATH")
  match env_config_path {
    Some(config_path) =>
      match parse_json_file_map(config_path) {
        Some(config) => return Some(config)
        None => ()
      }
    None => ()
  }
  let candidates = if is_windows_platform() {
    [
      state_dir + "\\openclaw.json",
      state_dir + "\\gateway.json",
      state_dir + "\\config.json",
      state_dir + "\\settings.json",
    ]
  } else {
    [
      state_dir + "/openclaw.json",
      state_dir + "/gateway.json",
      state_dir + "/config.json",
      state_dir + "/settings.json",
    ]
  }
  for path in candidates {
    match parse_json_file_map(path) {
      Some(config) => return Some(config)
      None => ()
    }
  }
  None
}

///|
fn resolve_config_auth_mode(state_config : Map[String, Json]?) -> String? {
  if state_config is Some(config) {
    first_non_empty(
      @jsonx.strs(config, ["gateway", "auth", "mode"]),
      first_non_empty(
        @jsonx.strs(config, ["gateway", "mode"]),
        @jsonx.strf(config, "auth_mode"),
      ),
    )
  } else {
    None
  }
}

///|
fn first_non_empty(a : String?, b : String?) -> String? {
  if a is Some(v) && v != "" {
    Some(v)
  } else {
    b
  }
}

///|
fn resolve_profile(state_config : Map[String, Json]?) -> String? {
  let env_profile = @sys.get_env_var("OPENCLAW_PROFILE")
  if env_profile is Some(v) {
    if v == "" {
      None
    } else {
      Some(v)
    }
  } else if state_config is Some(config) {
    @jsonx.strf(config, "profile")
  } else {
    None
  }
}

///|
fn parse_base_url_port(base_url : String) -> Int? {
  match @url.Url::parse(base_url) {
    Some(url) => {
      let port = url.get_port()
      if port == "" {
        if url.scheme == "https" {
          Some(443)
        } else {
          Some(80)
        }
      } else {
        (try? @strconv.parse_int(port)).to_option()
      }
    }
    None => None
  }
}

///|
fn resolve_openclaw_base_url(
  state_config : Map[String, Json]?,
) -> (String, Int) {
  if @sys.get_env_var("OPENCLAW_BASE_URL") is Some(v) {
    return (v, parse_base_url_port(v).unwrap_or(18789))
  }
  match @sys.get_env_var("OPENCLAW_GATEWAY_PORT") {
    Some(v) =>
      if (try? @strconv.parse_int(v)) is Ok(port) {
        return ("http://127.0.0.1:" + port.to_string(), port)
      }
    None => ()
  }
  if state_config is Some(config) {
    if first_non_empty(
        @jsonx.strf(config, "base_url"),
        @jsonx.strf(config, "gateway_url"),
      )
      is Some(v) {
      return (v, parse_base_url_port(v).unwrap_or(18789))
    }
    if @jsonx.intf(config, "gateway_port") is Some(port) {
      return ("http://127.0.0.1:" + port.to_string(), port)
    }
    if @jsonx.intf(config, "port") is Some(port) {
      return ("http://127.0.0.1:" + port.to_string(), port)
    }
  }
  ("http://127.0.0.1:18789", 18789)
}

///|
fn resolve_agent_id(state_config : Map[String, Json]?) -> String {
  if @sys.get_env_var("OPENCLAW_AGENT_ID") is Some(v) {
    if v == "" {
      "main"
    } else {
      v
    }
  } else if resolve_profile(state_config) is Some(v) {
    v
  } else if state_config is Some(config) {
    @jsonx.strf(config, "agent_id").unwrap_or("main")
  } else {
    "main"
  }
}

///|
fn resolve_auth(
  state_config : Map[String, Json]?,
) -> (String, String?, String?) {
  let configured_mode = resolve_config_auth_mode(state_config)
  let config_token = if app_state.config is Some(config) {
    config.openclaw_token
  } else {
    None
  }
  let token = first_non_empty(
    config_token,
    first_non_empty(
      @sys.get_env_var("OPENCLAW_GATEWAY_TOKEN"),
      @sys.get_env_var("OPENCLAW_TOKEN"),
    ),
  )
  let password = first_non_empty(
    @sys.get_env_var("OPENCLAW_GATEWAY_PASSWORD"),
    @sys.get_env_var("OPENCLAW_PASSWORD"),
  )
  let state_token = if state_config is Some(config) {
    first_non_empty(
      @jsonx.strs(config, ["gateway", "auth", "token"]),
      first_non_empty(
        @jsonx.strs(config, ["gateway", "token"]),
        first_non_empty(
          @jsonx.strf(config, "gateway_token"),
          @jsonx.strf(config, "token"),
        ),
      ),
    )
  } else {
    None
  }
  let state_password = if state_config is Some(config) {
    first_non_empty(
      @jsonx.strs(config, ["gateway", "auth", "password"]),
      first_non_empty(
        @jsonx.strs(config, ["gateway", "password"]),
        first_non_empty(
          @jsonx.strf(config, "gateway_password"),
          @jsonx.strf(config, "password"),
        ),
      ),
    )
  } else {
    None
  }
  let resolved_token = first_non_empty(token, state_token)
  let resolved_password = first_non_empty(password, state_password)
  match configured_mode {
    Some(mode) =>
      if mode.to_lower() == "password" {
        match resolved_password {
          Some(v) => ("password", None, Some(v))
          None =>
            match resolved_token {
              Some(v) => ("token", Some(v), None)
              None => ("none", None, None)
            }
        }
      } else if mode.to_lower() == "token" {
        match resolved_token {
          Some(v) => ("token", Some(v), None)
          None =>
            match resolved_password {
              Some(v) => ("password", None, Some(v))
              None => ("none", None, None)
            }
        }
      } else {
        match resolved_token {
          Some(v) => ("token", Some(v), None)
          None =>
            match resolved_password {
              Some(v) => ("password", None, Some(v))
              None => ("none", None, None)
            }
        }
      }
    None =>
      match resolved_token {
        Some(v) => ("token", Some(v), None)
        None =>
          match resolved_password {
            Some(v) => ("password", None, Some(v))
            None => ("none", None, None)
          }
      }
  }
}

///|
fn make_openclaw_instance_id(
  agent_id : String,
  port : Int,
  profile : String?,
) -> String {
  match profile {
    Some(p) => "openclaw:" + agent_id + ":" + port.to_string() + ":" + p
    None => "openclaw:" + agent_id + ":" + port.to_string()
  }
}

///|
fn make_openclaw_public_json(instance : OpenClawPublicInstance) -> Json {
  {
    "id": instance.id,
    "label": instance.label,
    "platform": instance.platform,
    "agent_id": instance.agent_id,
    "api": instance.api,
    "state": instance.state,
    "gateway_port": instance.gateway_port,
  }
}

///|
fn make_channel_json(channel : ChannelInstance) -> Json {
  {
    "id": channel.id,
    "type": channel.type_,
    "label": channel.label,
    "state": channel.state,
    "meta": channel.meta,
  }
}

///|
fn runtime_to_public(
  instance : OpenClawRuntimeInstance,
) -> OpenClawPublicInstance {
  {
    id: instance.id,
    label: instance.label,
    platform: instance.platform,
    agent_id: instance.agent_id,
    api: instance.api,
    state: instance.state,
    gateway_port: instance.gateway_port,
  }
}

///|
fn runtime_to_channel(instance : OpenClawRuntimeInstance) -> ChannelInstance {
  {
    id: instance.channel_id,
    type_: instance.channel_type,
    label: instance.label,
    state: instance.state,
    meta: make_openclaw_public_json(runtime_to_public(instance)),
  }
}

///|
fn find_substring(haystack : String, needle : String) -> Int? {
  if needle == "" || haystack.length() < needle.length() {
    return None
  }
  let max_idx = haystack.length() - needle.length()
  let mut idx = 0
  while idx <= max_idx {
    if haystack[idx:idx + needle.length()].to_string() == needle {
      return Some(idx)
    }
    idx = idx + 1
  }
  None
}

///|
fn parse_http_response(raw : String) -> (Int, Map[String, String], String)? {
  let header_end = match find_substring(raw, "\r\n\r\n") {
    Some(idx) => Some((idx, 4))
    None =>
      match find_substring(raw, "\n\n") {
        Some(idx) => Some((idx, 2))
        None => None
      }
  }
  match header_end {
    Some((idx, sep_len)) => {
      let header_text = raw[:idx].to_string()
      let body = raw[idx + sep_len:].to_string()
      let lines = header_text.split("\n").to_array()
      if lines.is_empty() {
        return None
      }
      let status_parts = lines[0].trim().split(" ").to_array()
      if status_parts.length() < 2 {
        return None
      }
      let status = @strconv.parse_int(status_parts[1].to_string()) catch {
        _ => 500
      }

      let headers : Map[String, String] = {}
      for i = 1; i < lines.length(); i = i + 1 {
        let line = lines[i].trim().to_string()
        match find_substring(line, ":") {
          Some(pos) => {
            let key = line[:pos].to_string()
            let value = line[pos + 1:].trim().to_string()
            if key != "" {
              headers[key] = value
            }
          }
          None => ()
        }
      }
      let decoded_body = match
        get_header_ignore_case(headers, "Transfer-Encoding") {
        Some(v) =>
          if v.to_lower().contains("chunked") {
            decode_chunked_body(body)
          } else {
            body
          }
        None => body
      }
      Some((status, headers, decoded_body))
    }
    None => None
  }
}

///|
fn get_header_ignore_case(
  headers : Map[String, String],
  key : String,
) -> String? {
  let key_lower = key.to_lower()
  for header_key, header_value in headers {
    if header_key.to_lower() == key_lower {
      return Some(header_value)
    }
  }
  None
}

///|
fn parse_hex_opt(s : String) -> Int? {
  let is_hex = lexmatch s[:] with longest {
    "[0-9A-Fa-f]+" => true
    _ => false
  }
  guard is_hex else { None }
  let mut result = 0
  for c in s.to_lower() {
    let digit = if c >= '0' && c <= '9' {
      c.to_int() - '0'.to_int()
    } else if c >= 'a' && c <= 'f' {
      10 + c.to_int() - 'a'.to_int()
    } else {
      return None
    }
    result = result * 16 + digit
  }
  Some(result)
}

///|
fn decode_chunked_body(body : String) -> String {
  let parts : Array[String] = []
  let mut offset = 0
  while offset < body.length() {
    let line_end = match find_substring(body[offset:].to_string(), "\r\n") {
      Some(pos) => offset + pos
      None => break
    }
    let size_line = body[offset:line_end].trim().to_string()
    let size_hex = match find_substring(size_line, ";") {
      Some(pos) => size_line[:pos].to_string()
      None => size_line
    }
    guard parse_hex_opt(size_hex) is Some(size) else { return body }
    offset = line_end + 2
    if size == 0 {
      break
    }
    if offset + size > body.length() {
      return body
    }
    parts.push(body[offset:offset + size].to_string())
    offset = offset + size
    if offset + 2 <= body.length() &&
      body[offset:offset + 2].to_string() == "\r\n" {
      offset = offset + 2
    }
  }
  parts.join("")
}

///|
async fn read_socket_all(conn : @socket.Tcp) -> String {
  let parts : Array[String] = []
  for ;; {
    match conn.read_some() {
      Some(chunk) =>
        if chunk.length() == 0 {
          break
        } else {
          parts.push(@utf8.decode(chunk) catch { _ => "" })
        }
      None => break
    }
  }
  parts.join("")
}

///|
async fn http_request(
  base_url : String,
  http_method : String,
  path : String,
  headers : Map[String, String],
  body : String,
) -> (Int, Map[String, String], String)? {
  match @url.Url::parse(base_url) {
    Some(url) => {
      if url.scheme != "http" {
        return None
      }
      let host = url.hostname()
      if host == "" {
        return None
      }
      let port = url.get_port()
      let target = host + ":" + (if port == "" { "80" } else { port })
      let request_path = if path.has_prefix("/") { path } else { "/" + path }
      let request_headers : Map[String, String] = {
        "Host": target,
        "Connection": "close",
        "Accept-Encoding": "identity",
        "Content-Length": @utf8.encode(body).length().to_string(),
      }
      for key, value in headers {
        request_headers[key] = value
      }
      let lines : Array[String] = [
        http_method + " " + request_path + " HTTP/1.1",
      ]
      for key, value in request_headers {
        lines.push(key + ": " + value)
      }
      let request = lines.join("\r\n") + "\r\n\r\n" + body
      let addr = @socket.Addr::parse(target) catch { _ => return None }
      let conn = @socket.Tcp::connect(addr) catch { _ => return None }
      conn.write(@utf8.encode(request)) catch {
        _ => return None
      }
      let response = read_socket_all(conn)
      parse_http_response(response)
    }
    None => None
  }
}

///|
async fn probe_openclaw_status(
  base_url : String,
  auth_mode : String,
  token : String?,
  password : String?,
) -> String {
  let headers : Map[String, String] = { "Accept": "application/json" }
  match auth_mode {
    "token" =>
      match token {
        Some(t) => headers["Authorization"] = "Bearer " + t
        None => return "auth_missing"
      }
    "password" =>
      match password {
        Some(p) => headers["Authorization"] = "Bearer " + p
        None => return "auth_missing"
      }
    "none" => ()
    _ => return "invalid_config"
  }
  match http_request(base_url, "GET", "/v1/models", headers, "") {
    Some((status, _, _)) =>
      if status == 404 {
        "endpoint_disabled"
      } else if status == 401 || status == 403 {
        if auth_mode == "none" {
          "auth_missing"
        } else {
          "ready"
        }
      } else if status >= 200 && status < 500 {
        "ready"
      } else {
        "gateway_down"
      }
    None => "gateway_down"
  }
}

///|
async fn discover_openclaw_instances() -> Array[OpenClawRuntimeInstance] {
  let platform = platform_name()
  let executables = find_executable_candidates(platform)
  let state_dirs = candidate_state_dirs()
  let found : Array[OpenClawRuntimeInstance] = []
  let seen : Map[String, Bool] = {}
  let profile_env = @sys.get_env_var("OPENCLAW_PROFILE")

  for state_dir in state_dirs {
    let state_config = read_state_dir_config(state_dir)
    let (base_url, port) = resolve_openclaw_base_url(state_config)
    let profile = match profile_env {
      Some(v) => Some(v)
      None => resolve_profile(state_config)
    }
    let (auth_mode, token, password) = resolve_auth(state_config)
    let state = probe_openclaw_status(base_url, auth_mode, token, password)
    let executable_path = if executables.is_empty() {
      None
    } else {
      Some(executables[0])
    }
    let agent_ids = discover_openclaw_agent_ids(state_dir)
    for agent_id in agent_ids {
      let instance_id = make_openclaw_instance_id(agent_id, port, profile)
      if seen.contains(instance_id) {
        continue
      }
      found.push(OpenClawRuntimeInstance::{
        id: instance_id,
        channel_id: instance_id,
        channel_type: "openclaw",
        label: "OpenClaw " + agent_id,
        platform,
        agent_id,
        api: "openai-chat-completions",
        state,
        gateway_port: port,
        base_url,
        auth_mode,
        token,
        password,
        executable_path,
        state_dir: Some(state_dir),
        profile,
      })
      seen[instance_id] = true
    }
  }

  if found.is_empty() && !executables.is_empty() {
    let profile = profile_env
    let instance_id = make_openclaw_instance_id("main", 18789, profile)
    let (auth_mode, token, password) = resolve_auth(None)
    let state = probe_openclaw_status(
      "http://127.0.0.1:18789", auth_mode, token, password,
    )
    found.push(OpenClawRuntimeInstance::{
      id: instance_id,
      channel_id: instance_id,
      channel_type: "openclaw",
      label: "OpenClaw main",
      platform,
      agent_id: "main",
      api: "openai-chat-completions",
      state,
      gateway_port: 18789,
      base_url: "http://127.0.0.1:18789",
      auth_mode,
      token,
      password,
      executable_path: Some(executables[0]),
      state_dir: None,
      profile,
    })
  }

  found
}

///|
async fn refresh_openclaw_registry() -> Unit {
  openclaw_state.runtimes = discover_openclaw_instances()
}

///|
fn get_openclaw_runtime(channel_id : String) -> OpenClawRuntimeInstance? {
  for runtime in openclaw_state.runtimes {
    if runtime.channel_id == channel_id || runtime.id == channel_id {
      return Some(runtime)
    }
  }
  None
}

///|
fn get_openclaw_metadata_json() -> String {
  let items : Array[Json] = []
  for runtime in openclaw_state.runtimes {
    items.push(make_openclaw_public_json(runtime_to_public(runtime)))
  }
  items.to_json().stringify()
}

///|
fn get_channel_metadata_json() -> String {
  let items : Array[Json] = []
  for runtime in openclaw_state.runtimes {
    items.push(make_channel_json(runtime_to_channel(runtime)))
  }
  items.to_json().stringify()
}

///|
fn build_openclaw_request_json(
  runtime : OpenClawRuntimeInstance,
  messages : Array[Json],
  session_key : String,
  stream : Bool,
) -> Json {
  {
    "model": "openclaw:" + runtime.agent_id,
    "messages": messages,
    "stream": stream,
    "user": session_key,
  }
}

///|
fn extract_openclaw_response_message(raw : Map[String, Json]) -> Json {
  let fallback : Json = { "role": "assistant", "content": "" }
  match raw.get("choices") {
    Some(Array(choices)) => {
      for choice in choices {
        match choice {
          Object(choice_obj) =>
            match choice_obj.get("message") {
              Some(Object(message_obj)) => return message_obj.to_json()
              _ => ()
            }
          _ => ()
        }
      }
      fallback
    }
    _ => fallback
  }
}

///|
fn try_parse_openclaw_json(body : String) -> Json? {
  Some(@json.parse(body)) catch {
    _ => None
  }
}

///|
fn extract_sse_json_payload(body : String) -> String? {
  let payloads : Array[String] = []
  for raw_line in body.split("\n") {
    let line = raw_line.trim().to_string()
    if !line.has_prefix("data:") {
      continue
    }
    let payload = line[5:].trim().to_string()
    if payload == "" || payload == "[DONE]" {
      continue
    }
    payloads.push(payload)
  }
  if payloads.is_empty() {
    None
  } else {
    let mut idx = payloads.length()
    while idx > 0 {
      idx = idx - 1
      let payload = payloads[idx]
      if try_parse_openclaw_json(payload) is Some(_) {
        return Some(payload)
      }
    }
    Some(payloads[0])
  }
}

///|
fn normalize_openclaw_response(
  body : String,
  headers : Map[String, String],
) -> Json? {
  match try_parse_openclaw_json(body) {
    Some(parsed) => Some(parsed)
    None =>
      match get_header_ignore_case(headers, "Content-Type") {
        Some(content_type) =>
          if content_type.to_lower().contains("text/event-stream") {
            match extract_sse_json_payload(body) {
              Some(payload) => try_parse_openclaw_json(payload)
              None => None
            }
          } else {
            match extract_sse_json_payload(body) {
              Some(payload) => try_parse_openclaw_json(payload)
              None => None
            }
          }
        None =>
          match extract_sse_json_payload(body) {
            Some(payload) => try_parse_openclaw_json(payload)
            None => None
          }
      }
  }
}

///|
async fn chat_with_openclaw_local(
  channel_id : String,
  messages : Array[Json],
  session_key : String,
  stream : Bool,
) -> (Int, Json) {
  match get_openclaw_runtime(channel_id) {
    Some(runtime) =>
      if runtime.state != "ready" && runtime.state != "auth_missing" {
        (
          409,
          {
            "error": "channel_unavailable",
            "channel_id": channel_id,
            "state": runtime.state,
          },
        )
      } else {
        let headers : Map[String, String] = {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "x-openclaw-agent-id": runtime.agent_id,
        }
        match runtime.auth_mode {
          "token" =>
            match runtime.token {
              Some(token) => headers["Authorization"] = "Bearer " + token
              None =>
                return (
                  409,
                  { "error": "auth_missing", "channel_id": channel_id },
                )
            }
          "password" =>
            match runtime.password {
              Some(password) => headers["Authorization"] = "Bearer " + password
              None =>
                return (
                  409,
                  { "error": "auth_missing", "channel_id": channel_id },
                )
            }
          _ => ()
        }
        let request_body = build_openclaw_request_json(
          runtime, messages, session_key, stream,
        ).stringify()
        match
          http_request(
            runtime.base_url,
            "POST",
            "/v1/chat/completions",
            headers,
            request_body,
          ) {
          Some((status, resp_headers, body)) => {
            let content_type = get_header_ignore_case(
              resp_headers, "Content-Type",
            ).unwrap_or("")
            if status == 404 &&
              content_type.to_lower().contains("text/plain") &&
              body.trim() == "Not Found" {
              return (
                409,
                {
                  "error": "endpoint_disabled",
                  "channel_id": channel_id,
                  "status": status,
                  "headers": resp_headers,
                  "body": body,
                  "hint": "Enable gateway.http.endpoints.chatCompletions.enabled in OpenClaw config",
                },
              )
            }
            let parsed = match normalize_openclaw_response(body, resp_headers) {
              Some(parsed) => parsed
              None =>
                return (
                  502,
                  {
                    "error": "invalid_openclaw_response",
                    "status": status,
                    "headers": resp_headers,
                    "body": body,
                  },
                )
            }
            match parsed {
              Object(raw) =>
                if status >= 200 && status < 300 {
                  (
                    200,
                    {
                      "channel_id": runtime.channel_id,
                      "instance_id": runtime.id,
                      "peer_id": get_config().id,
                      "message": extract_openclaw_response_message(raw),
                      "model": "openclaw:" + runtime.agent_id,
                      "raw": raw,
                    },
                  )
                } else {
                  (
                    502,
                    {
                      "error": "openclaw_request_failed",
                      "status": status,
                      "headers": resp_headers,
                      "raw": raw,
                    },
                  )
                }
              _ =>
                (
                  502,
                  {
                    "error": "invalid_openclaw_response",
                    "status": status,
                    "headers": resp_headers,
                    "body": body,
                  },
                )
            }
          }
          None =>
            (502, { "error": "openclaw_unreachable", "channel_id": channel_id })
        }
      }
    None => (404, { "error": "channel_not_found", "channel_id": channel_id })
  }
}

///|
fn init_openclaw_registry(root : @async.TaskGroup[Unit]) -> Unit {
  let _ = root.spawn_bg(async fn() {
    refresh_openclaw_registry()
    for ;; {
      @async.sleep(30000)
      refresh_openclaw_registry()
    }
  })
}
