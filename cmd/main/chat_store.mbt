///|
fn is_persistable_chat_kind(kind : String) -> Bool {
  kind == "text" || kind == "file" || kind == "image" || kind == "video"
}

///|
async fn init_chat_store() -> Unit {
  let db_dir = @fs.tmpdir(prefix="msgtier")

  if !@fs.exists(db_dir) {
    @fs.mkdir(db_dir, permission=0o755)
  }

  let db_file = db_dir + "/chat.sqlite3"
  println("Chat DB file: \{db_file}")
  try {
    let engine = @sqlite3.SQLiteEngine::open(db_file)
    @morm.auto_migrate(engine, [@db.Message::table()])
    let mapper = @db.MessageMapperImpl::new(engine)
    http_state.chat_mapper = Some(mapper)
    http_state.chat_engine = Some(engine)
  } catch {
    e => log_warn("Failed to initialize chat store: \{e}")
  }
}

///|
async fn persist_chat_message(msg : Message) -> Unit {
  if !is_persistable_chat_kind(msg.kind) {
    return
  }
  if http_state.chat_mapper is Some(mapper) {
    ignore(
      mapper.save(@db.Message::{
        id: msg.id,
        source_id: msg.source_id,
        target_id: Some(msg.target_id.unwrap_or("broadcast")),
        kind: msg.kind,
        content: msg.body.to_json().stringify(),
        timestamp: msg.timestamp.to_string(),
      }),
    ) catch {
      e => log_warn("Failed to persist chat message \{msg.id}: \{e}")
    }
  }
}

///|
fn parse_chat_timestamp(timestamp : String) -> UInt64 {
  match parse_decimal_opt(timestamp) {
    Some(v) => if v < 0 { 0UL } else { v.to_uint64() }
    None => 0UL
  }
}

///|
async fn emit_channel_chat_message(
  source_id : String,
  target_id : String,
  content : String,
) -> Unit {
  let msg = Message::new(
    kind="text",
    source_id~,
    target_id~,
    body=@msgpack.string(content),
    relay=1,
    version=app_state.version,
    timeout_ms=30000,
  )
  emit_ws_message(msg)
}
