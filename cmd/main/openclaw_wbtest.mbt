///|
test "resolve_auth prefers config token" {
  app_state.config = Some({
    id: "node-a",
    secret: "secret",
    peers: [],
    listeners: [],
    scripts: None,
    web_api: None,
    metadata: None,
    openclaw: None,
    openclaw_plugin_version: None,
    openclaw_token: Some("config-token"),
    port_forward_exposes: None,
    port_forward_forwards: None,
    log: None,
    port: None,
    relay_network_whitelist: None,
    relay_all_peer_rpc: None,
    foreign_relay_bps_limit: None,
    upload_dir: None,
    disable_encryption: None,
  })
  let (auth_mode, token, password) = resolve_auth(None)
  inspect(auth_mode, content="token")
  inspect(token.unwrap(), content="config-token")
  inspect(password is None, content="true")
}

///|
test "resolve_auth reads nested gateway auth token from state config" {
  app_state.config = Some({
    id: "node-a",
    secret: "secret",
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
  })
  let state_config : Map[String, Json] = {
    "gateway": { "auth": { "token": "state-token" } },
  }
  let (auth_mode, token, password) = resolve_auth(Some(state_config))
  inspect(auth_mode, content="token")
  inspect(token.unwrap(), content="state-token")
  inspect(password is None, content="true")
}

///|
test "resolve_auth respects configured password mode" {
  app_state.config = Some({
    id: "node-a",
    secret: "secret",
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
  })
  let state_config : Map[String, Json] = {
    "gateway": {
      "auth": {
        "mode": "password",
        "token": "state-token",
        "password": "state-password",
      },
    },
  }
  let (auth_mode, token, password) = resolve_auth(Some(state_config))
  inspect(auth_mode, content="password")
  inspect(token is None, content="true")
  inspect(password.unwrap(), content="state-password")
}

///|
test "openclaw auto manage flag and plugin assets are generated" {
  app_state.config = Some({
    id: "node-a",
    secret: "secret",
    peers: [],
    listeners: [],
    scripts: None,
    web_api: None,
    metadata: None,
    openclaw: Some(true),
    openclaw_plugin_version: Some("1.2.3"),
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
  })
  inspect(openclaw_auto_manage_enabled(), content="true")
  inspect(
    msgtier_openclaw_package_json().contains("\"name\": \"msgtier\""),
    content="true",
  )
  inspect(
    msgtier_openclaw_package_json().contains("\"version\": \"1.2.3\""),
    content="true",
  )
  inspect(
    msgtier_openclaw_plugin_manifest_json().contains("\"id\": \"msgtier\""),
    content="true",
  )
  inspect(
    msgtier_openclaw_index_js().contains("id: \"msgtier\""),
    content="true",
  )
}

///|
test "openclaw metadata exports channels and public instances" {
  openclaw_state.runtimes = [
    OpenClawRuntimeInstance::{
      id: "openclaw:research:18789",
      channel_id: "openclaw:research:18789",
      channel_type: "openclaw",
      label: "OpenClaw research",
      platform: "macos",
      agent_id: "research",
      api: "openai-chat-completions",
      state: "ready",
      gateway_port: 18789,
      base_url: "http://127.0.0.1:18789",
      auth_mode: "token",
      token: Some("secret"),
      password: None,
      executable_path: Some("/opt/homebrew/bin/openclaw"),
      state_dir: Some("/Users/test/.openclaw"),
      profile: Some("main"),
    },
    OpenClawRuntimeInstance::{
      id: "openclaw:main:18789",
      channel_id: "openclaw:main:18789",
      channel_type: "openclaw",
      label: "OpenClaw main",
      platform: "macos",
      agent_id: "main",
      api: "openai-chat-completions",
      state: "ready",
      gateway_port: 18789,
      base_url: "http://127.0.0.1:18789",
      auth_mode: "token",
      token: Some("secret"),
      password: None,
      executable_path: Some("/opt/homebrew/bin/openclaw"),
      state_dir: Some("/Users/test/.openclaw"),
      profile: Some("main"),
    },
  ]

  inspect(
    get_openclaw_metadata_json().contains("openclaw:main:18789"),
    content="true",
  )
  inspect(
    get_openclaw_metadata_json().contains("openclaw:research:18789"),
    content="true",
  )
  inspect(get_openclaw_metadata_json().contains("secret"), content="false")
  inspect(
    get_channel_metadata_json().contains("\"type\":\"openclaw\""),
    content="true",
  )
}

///|
test "build openclaw request uses agent and user session" {
  let runtime = OpenClawRuntimeInstance::{
    id: "openclaw:main:18789",
    channel_id: "openclaw:main:18789",
    channel_type: "openclaw",
    label: "OpenClaw main",
    platform: "linux",
    agent_id: "main",
    api: "openai-chat-completions",
    state: "ready",
    gateway_port: 18789,
    base_url: "http://127.0.0.1:18789",
    auth_mode: "none",
    token: None,
    password: None,
    executable_path: None,
    state_dir: None,
    profile: None,
  }
  let req = build_openclaw_request_json(
    runtime,
    [{ "role": "user", "content": "hello" }],
    "chat:a:b:c",
    false,
  ).stringify()
  inspect(req.contains("\"model\":\"openclaw:main\""), content="true")
  inspect(req.contains("\"user\":\"chat:a:b:c\""), content="true")
}

///|
test "parse_http_response handles content-length json body" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 17\r\n\r\n{\"ok\":true,\"n\":1}"
  let parsed = parse_http_response(raw).unwrap()
  let (status, headers, body) = parsed
  inspect(status, content="200")
  inspect(headers.get("Content-Type").unwrap(), content="application/json")
  inspect(body, content="{\"ok\":true,\"n\":1}")
}

///|
test "parse_http_response decodes chunked json body case-insensitive header" {
  let raw = "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ntransfer-encoding: chunked\r\n\r\n11\r\n{\"ok\":true,\"n\":1}\r\n0\r\n\r\n"
  let parsed = parse_http_response(raw).unwrap()
  let (status, headers, body) = parsed
  inspect(status, content="200")
  inspect(headers.get("content-type").unwrap(), content="application/json")
  inspect(body, content="{\"ok\":true,\"n\":1}")
}

///|
test "decode_chunked_body handles chunk extensions" {
  let body = "11;foo=bar\r\n{\"ok\":true,\"n\":1}\r\n0\r\n\r\n"
  inspect(decode_chunked_body(body), content="{\"ok\":true,\"n\":1}")
}

///|
test "normalize_openclaw_response handles sse payload" {
  let headers : Map[String, String] = { "content-type": "text/event-stream" }
  let body = "event: message\n" +
    "data: {\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"hi\"}}]}\n\n" +
    "data: [DONE]\n"
  let parsed = normalize_openclaw_response(body, headers).unwrap()
  inspect(parsed.stringify().contains("\"content\":\"hi\""), content="true")
}
