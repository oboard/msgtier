///|
fn query_param(query : String?, key : String) -> String? {
  match query {
    Some(q) => {
      let prefix = key + "="
      for part in q.split("&") {
        let p = part.to_string()
        if p.has_prefix(prefix) {
          return Some(p[prefix.length():].to_string())
        }
      }
      None
    }
    None => None
  }
}

///|
fn parse_channel_target_id(target_id : String) -> (String, String)? {
  lexmatch target_id[:] with longest {
    ("channel::" ("[^:]+" as peer_id) "::" (".+" as channel_id)) =>
      Some((peer_id.to_string(), channel_id.to_string()))
    _ => None
  }
}

///|
fn is_openclaw_channel_target_id(target_id : String) -> Bool {
  if parse_channel_target_id(target_id) is Some((_, channel_id)) {
    channel_id.has_prefix("openclaw:")
  } else {
    false
  }
}

///|
fn chat_page_has_items(page : Json) -> Bool {
  match page {
    Object(obj) =>
      match obj.get("items") {
        Some(Array(items)) => !items.is_empty()
        _ => false
      }
    _ => false
  }
}

///|
fn normalize_iso_millis(millis_text : String) -> Int {
  let value = @strconv.parse_int(millis_text) catch { _ => 0 }
  if millis_text.length() == 1 {
    value * 100
  } else if millis_text.length() == 2 {
    value * 10
  } else {
    @strconv.parse_int(millis_text[:3]) catch {
      _ => value
    }
  }
}

///|
fn parse_iso_utc_timestamp(timestamp : String) -> UInt64? {
  let (year, month, day, hour, minute, second, millis) = lexmatch
    timestamp[:] with longest {
    (
      ("[0-9]{4}" as year)
      "-"
      ("[0-9]{2}" as month)
      "-"
      ("[0-9]{2}" as day)
      "T"
      ("[0-9]{2}" as hour)
      ":"
      ("[0-9]{2}" as minute)
      ":"
      ("[0-9]{2}" as second)
      "."
      ("[0-9]{1,9}" as millis_text)
      "Z"
    ) =>
      (
        @strconv.parse_int(year) catch {
          _ => 0
        },
        @strconv.parse_int(month) catch {
          _ => 0
        },
        @strconv.parse_int(day) catch {
          _ => 0
        },
        @strconv.parse_int(hour) catch {
          _ => 0
        },
        @strconv.parse_int(minute) catch {
          _ => 0
        },
        @strconv.parse_int(second) catch {
          _ => 0
        },
        normalize_iso_millis(millis_text.to_string()),
      )
    (
      ("[0-9]{4}" as year)
      "-"
      ("[0-9]{2}" as month)
      "-"
      ("[0-9]{2}" as day)
      "T"
      ("[0-9]{2}" as hour)
      ":"
      ("[0-9]{2}" as minute)
      ":"
      ("[0-9]{2}" as second)
      "Z"
    ) =>
      (
        @strconv.parse_int(year) catch {
          _ => 0
        },
        @strconv.parse_int(month) catch {
          _ => 0
        },
        @strconv.parse_int(day) catch {
          _ => 0
        },
        @strconv.parse_int(hour) catch {
          _ => 0
        },
        @strconv.parse_int(minute) catch {
          _ => 0
        },
        @strconv.parse_int(second) catch {
          _ => 0
        },
        0,
      )
    _ => return None
  }
  let month_adj = if month <= 2 { month + 9 } else { month - 3 }
  let year_adj = if month <= 2 { year - 1 } else { year }
  let era = if year_adj >= 0 { year_adj / 400 } else { (year_adj - 399) / 400 }
  let yoe = year_adj - era * 400
  let doy = (153 * month_adj + 2) / 5 + day - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  let days = era * 146097 + doe - 719468
  let total_ms = (
      ((days.to_int64() * 24L + hour.to_int64()) * 60L + minute.to_int64()) *
      60L +
      second.to_int64()
    ) *
    1000L +
    millis.to_int64()
  if total_ms < 0L {
    None
  } else {
    Some(total_ms.reinterpret_as_uint64())
  }
}

///|
fn extract_openclaw_text_blocks(content : Json) -> String {
  match content {
    Array(items) => {
      let parts : Array[String] = []
      for item in items {
        match item {
          Object(obj) =>
            match (obj.get("type"), obj.get("text")) {
              (Some(String(type_)), Some(String(text))) =>
                if type_ == "text" && text != "" {
                  parts.push(text)
                }
              _ => ()
            }
          _ => ()
        }
      }
      parts.join("\n\n")
    }
    String(text) => text
    _ => ""
  }
}

///|
fn make_openclaw_history_message_json(
  msg_id : String,
  source_id : String,
  target_id : String,
  timestamp : UInt64,
  content : String,
) -> Json {
  {
    "id": msg_id,
    "kind": "text",
    "source_id": source_id,
    "target_id": target_id,
    "timestamp": timestamp,
    "content": content,
  }
}

///|
async fn load_openclaw_session_messages_json(
  target_id : String,
  requester_id : String,
  limit : Int,
  before : UInt64?,
) -> Json {
  guard parse_channel_target_id(target_id) is Some((peer_id, channel_id)) else {
    return empty_chat_page_json()
  }
  let runtime = match get_openclaw_runtime(channel_id) {
    Some(v) => v
    None => return empty_chat_page_json()
  }
  let state_dir = runtime.state_dir.unwrap_or(default_openclaw_state_dir())
  let sessions_dir = path_join(
    path_join(path_join(state_dir, "agents"), runtime.agent_id),
    "sessions",
  )
  let sessions_index_path = path_join(sessions_dir, "sessions.json")
  let session_key = "agent:" +
    runtime.agent_id +
    ":openai-user:chat:" +
    requester_id +
    ":" +
    peer_id +
    ":" +
    runtime.channel_id
  let session_file = match parse_json_file_map(sessions_index_path) {
    Some(index_root) =>
      match index_root.get(session_key) {
        Some(Object(session_obj)) =>
          match session_obj.get("sessionFile") {
            Some(String(path)) => Some(path)
            _ =>
              match session_obj.get("sessionId") {
                Some(String(session_id)) =>
                  Some(path_join(sessions_dir, session_id + ".jsonl"))
                _ => None
              }
          }
        _ => None
      }
    None => None
  }
  let path = match session_file {
    Some(v) => v
    None => return empty_chat_page_json()
  }
  let text = @fs.read_file(path).text() catch {
    _ => return empty_chat_page_json()
  }
  let rows : Array[Json] = []
  for line in text.split("\n") {
    let line_text = line.trim().to_string()
    if line_text == "" {
      continue
    }
    let parsed = @json.parse(line_text) catch { _ => continue }
    match parsed {
      Object(obj) =>
        match (obj.get("type"), obj.get("message"), obj.get("timestamp")) {
          (Some(String(type_)), Some(Object(message_obj)), Some(String(ts))) => {
            if type_ != "message" {
              continue
            }
            match (message_obj.get("role"), message_obj.get("content")) {
              (Some(String(role)), Some(content_json)) => {
                let content = extract_openclaw_text_blocks(content_json)
                if content == "" {
                  continue
                }
                let timestamp = parse_iso_utc_timestamp(ts).unwrap_or(0UL)
                if before is Some(cursor) && timestamp >= cursor {
                  continue
                }
                let item_id = match obj.get("id") {
                  Some(String(id)) => "openclaw-session:" + id
                  _ => "openclaw-session:" + timestamp.to_string()
                }
                if role == "user" {
                  rows.push(
                    make_openclaw_history_message_json(
                      item_id, requester_id, target_id, timestamp, content,
                    ),
                  )
                } else if role == "assistant" {
                  rows.push(
                    make_openclaw_history_message_json(
                      item_id, target_id, requester_id, timestamp, content,
                    ),
                  )
                }
              }
              _ => ()
            }
          }
          _ => ()
        }
      _ => ()
    }
  }
  rows.sort_by(fn(a, b) {
    let at = match a {
      Object(obj) =>
        match obj.get("timestamp") {
          Some(Number(v, ..)) => v.to_int64()
          _ => 0L
        }
      _ => 0L
    }
    let bt = match b {
      Object(obj) =>
        match obj.get("timestamp") {
          Some(Number(v, ..)) => v.to_int64()
          _ => 0L
        }
      _ => 0L
    }
    if at > bt {
      -1
    } else if at < bt {
      1
    } else {
      0
    }
  })
  let has_more = rows.length() > limit
  let take_n = if has_more { limit } else { rows.length() }
  let items : Array[Json] = []
  let mut i = take_n
  while i > 0 {
    i = i - 1
    items.push(rows[i])
  }
  let next_before = if take_n == 0 {
    (-1).to_json()
  } else {
    match rows[take_n - 1] {
      Object(obj) =>
        match obj.get("timestamp") {
          Some(Number(v, ..)) =>
            if v.to_int64() > 0L {
              (v.to_int64() - 1L).to_json()
            } else {
              (0).to_json()
            }
          _ => (-1).to_json()
        }
      _ => (-1).to_json()
    }
  }
  {
    "items": items.to_json(),
    "has_more": has_more.to_json(),
    "next_before": next_before,
  }
}
