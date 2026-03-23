///|
fn parse_chat_limit(raw : String?) -> Int {
  let default_limit = 30
  match raw {
    Some(s) =>
      if (try? @strconv.parse_int(s)) is Ok(v) {
        if v < 1 {
          default_limit
        } else if v > 100 {
          100
        } else {
          v
        }
      } else {
        default_limit
      }
    None => default_limit
  }
}

///|
fn parse_chat_before(raw : String?) -> UInt64? {
  match raw {
    Some(s) =>
      if (try? @strconv.parse_int(s)) is Ok(v) {
        if v < 0 {
          None
        } else {
          Some(v.to_uint64())
        }
      } else {
        None
      }
    None => None
  }
}

///|
fn parse_chat_query(query : String?) -> (String, Int, UInt64?) {
  let mut peer_id = "broadcast"
  let mut limit_raw = None
  let mut before_raw = None

  if query is Some(q) {
    for part in q.split("&") {
      let p = part.to_string()
      if p.has_prefix("peer=") {
        let v = p[5:].to_string()
        peer_id = if v == "" { "broadcast" } else { v }
      } else if p.has_prefix("limit=") {
        limit_raw = Some(p[6:].to_string())
      } else if p.has_prefix("before=") {
        before_raw = Some(p[7:].to_string())
      }
    }
  }

  let limit = parse_chat_limit(limit_raw)
  let before = parse_chat_before(before_raw)
  (peer_id, limit, before)
}

///|
fn to_chat_message_json(msg : @db.Message) -> Json {
  let content = @json.parse(msg.content) catch { _ => msg.content.to_json() }
  {
    "id": msg.id,
    "kind": msg.kind,
    "source_id": msg.source_id,
    "target_id": msg.target_id.unwrap_or("broadcast"),
    "timestamp": parse_chat_timestamp(msg.timestamp),
    "content": content,
  }
}

///|
fn apply_before_cursor(q : @morm.Query, before : UInt64?) -> @morm.Query {
  match before {
    Some(cursor) => q.where_lt("timestamp", cursor.to_string())
    None => q
  }
}

///|
fn empty_chat_page_json() -> Json {
  let empty : Array[Json] = []
  { "items": empty.to_json(), "has_more": false, "next_before": (-1).to_json() }
}

///|
async fn load_chat_rows_or_empty(
  engine : @sqlite3.SQLiteEngine,
  q : @morm.Query,
  log_prefix : String,
) -> FixedArray[@db.Message]? {
  Some(engine.exec(q).rows.map(row => @db.Message::from_row(row))) catch {
    e => {
      log_warn("\{log_prefix}: \{e}")
      None
    }
  }
}

///|
fn merge_sorted_messages(
  groups : Array[FixedArray[@db.Message]],
) -> Array[@db.Message] {
  let out : Array[@db.Message] = []
  let seen : Map[String, Bool] = {}
  for group in groups {
    for msg in group {
      if seen.contains(msg.id) {
        continue
      }
      seen[msg.id] = true
      out.push(msg)
    }
  }
  out.sort_by(fn(a, b) {
    let at = parse_chat_timestamp(a.timestamp)
    let bt = parse_chat_timestamp(b.timestamp)
    if at > bt {
      -1
    } else if at < bt {
      1
    } else {
      0
    }
  })
  out
}

///|
async fn list_chat_messages_page_json(
  peer_id : String,
  limit : Int,
  before : UInt64?,
) -> Json {
  let my_id = get_config().id
  match http_state.chat_engine {
    Some(engine) => {
      let page_size = limit + 1
      let all_rows : Array[FixedArray[@db.Message]] = []
      if peer_id == "broadcast" {
        let broadcast_q = apply_before_cursor(
          @morm.select_from("message")
          .where_eq("target_id", "broadcast")
          .order_by(Desc("timestamp"))
          .limit(page_size),
          before,
        )
        if load_chat_rows_or_empty(
            engine, broadcast_q, "Failed to load broadcast messages",
          )
          is Some(broadcast_rows) {
          all_rows.push(broadcast_rows)
        } else {
          return empty_chat_page_json()
        }
      } else {
        let incoming_q = apply_before_cursor(
          @morm.select_from("message")
          .where_eq("source_id", peer_id)
          .where_eq("target_id", my_id)
          .order_by(Desc("timestamp"))
          .limit(page_size),
          before,
        )
        if load_chat_rows_or_empty(
            engine, incoming_q, "Failed to load incoming direct messages",
          )
          is Some(incoming_rows) {
          all_rows.push(incoming_rows)
        } else {
          return empty_chat_page_json()
        }

        let outgoing_q = apply_before_cursor(
          @morm.select_from("message")
          .where_eq("source_id", my_id)
          .where_eq("target_id", peer_id)
          .order_by(Desc("timestamp"))
          .limit(page_size),
          before,
        )
        if load_chat_rows_or_empty(
            engine, outgoing_q, "Failed to load outgoing direct messages",
          )
          is Some(outgoing_rows) {
          all_rows.push(outgoing_rows)
        } else {
          return empty_chat_page_json()
        }
      }

      let rows = merge_sorted_messages(all_rows)
      let has_more = rows.length() > limit
      let take_n = if has_more { limit } else { rows.length() }
      let page : Array[@db.Message] = []
      for i = 0; i < take_n; i = i + 1 {
        page.push(rows[i])
      }

      let items : Array[Json] = []
      let mut i = page.length()
      while i > 0 {
        i = i - 1
        items.push(to_chat_message_json(page[i]))
      }

      let next_before = if page.is_empty() {
        (-1).to_json()
      } else {
        let oldest_ts = parse_chat_timestamp(page[page.length() - 1].timestamp)
        if oldest_ts > 0UL {
          (oldest_ts - 1UL).to_json()
        } else {
          (0).to_json()
        }
      }

      {
        "items": items.to_json(),
        "has_more": has_more,
        "next_before": next_before,
      }
    }
    None => empty_chat_page_json()
  }
}

///|
async fn chat_messages_handler(
  conn : @http.ServerConnection,
  query : String?,
) -> Unit {
  let (peer_id, limit, before) = parse_chat_query(query)
  let my_id = get_config().id
  let local_page = list_chat_messages_page_json(peer_id, limit, before)
  let page = if is_openclaw_channel_target_id(peer_id) &&
    !chat_page_has_items(local_page) {
    match parse_channel_target_id(peer_id) {
      Some((target_peer_id, _)) =>
        if target_peer_id == my_id {
          load_openclaw_session_messages_json(peer_id, my_id, limit, before)
        } else {
          let requester_id = query_param(query, "requester_id").unwrap_or(my_id)
          let path = "/api/chat/messages/openclaw/local?peer=" +
            peer_id +
            "&limit=" +
            limit.to_string() +
            "&requester_id=" +
            requester_id +
            (match before {
              Some(cursor) => "&before=" + cursor.to_string()
              None => ""
            })
          match
            proxy_http_request(target_peer_id, "GET", path, {}, b"", 30000) {
            Some((status_code, _, resp_body)) =>
              if status_code >= 200 && status_code < 300 {
                @json.parse(@utf8.decode(resp_body)) catch {
                  _ => local_page
                }
              } else {
                local_page
              }
            None => local_page
          }
        }
      None => local_page
    }
  } else {
    local_page
  }
  let body = page.stringify()
  conn
  ..send_response(200, "OK", extra_headers={
    "Content-Type": "application/json",
  })
  ..write(body)
  .end_response()
}
