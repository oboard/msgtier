///|
let chat_db_file : Ref[String] = Ref::new("")

///|
fn is_persistable_chat_kind(kind : String) -> Bool {
  kind == "text" || kind == "file" || kind == "image" || kind == "video"
}

///|
fn get_chat_db_file() -> String {
  chat_db_file.val
}

///|
async fn init_chat_store() -> Unit {
  let runtime_dir = get_runtime_tmp_dir()
  let db_dir = if runtime_dir == "" {
    @fs.tmpdir(prefix="msgtier")
  } else {
    runtime_dir
  }

  if !@fs.exists(db_dir) {
    @fs.mkdir(db_dir, permission=0o755)
  }

  let db_file = db_dir + "/chat.sqlite3"
  chat_db_file.val = db_file
  try {
    let conn = @sqlite3.Connection::open(db_file)
    defer (conn.close() catch { _ => () })
    let stmt = conn.prepare(
      "CREATE TABLE IF NOT EXISTS message (" +
      "id TEXT PRIMARY KEY, " +
      "source_id TEXT NOT NULL, " +
      "target_id TEXT, " +
      "kind TEXT NOT NULL, " +
      "content TEXT NOT NULL, " +
      "timestamp TEXT NOT NULL" +
      ")",
    )
    defer (stmt.finalize() catch { _ => () })
    stmt.step_once()
  } catch {
    e => log_warn("Failed to initialize chat store: \{e}")
  }
}

///|
fn persist_chat_message(msg : Message) -> Unit {
  if !is_persistable_chat_kind(msg.kind) {
    return
  }

  let db_file = get_chat_db_file()
  if db_file == "" {
    return
  }

  try {
    let conn = @sqlite3.Connection::open(db_file)
    defer (conn.close() catch { _ => () })
    let stmt = conn.prepare(
      "INSERT OR REPLACE INTO message " +
      "(id, source_id, target_id, kind, content, timestamp) " +
      "VALUES (?, ?, ?, ?, ?, ?)",
    )
    defer (stmt.finalize() catch { _ => () })
    stmt.bind_text(index=0, val=msg.id)
    stmt.bind_text(index=1, val=msg.source_id)
    match msg.target_id {
      Some(target_id) => stmt.bind_text(index=2, val=target_id)
      None => stmt.bind_null(index=2)
    }
    stmt.bind_text(index=3, val=msg.kind)
    stmt.bind_text(index=4, val=msg.body.to_json().stringify())
    stmt.bind_text(index=5, val=msg.timestamp.to_string())
    stmt.step_once()
  } catch {
    e => log_warn("Failed to persist chat message \{msg.id}: \{e}")
  }
}

///|
fn list_chat_messages_json() -> Json {
  let db_file = get_chat_db_file()
  if db_file == "" {
    let empty : Array[Json] = []
    return empty.to_json()
  }

  try {
    let items : Array[Json] = []
    let conn = @sqlite3.Connection::open(db_file)
    defer (conn.close() catch { _ => () })
    let stmt = conn.prepare(
      "SELECT id, source_id, target_id, kind, content, timestamp " +
      "FROM message " +
      "ORDER BY CAST(timestamp AS INTEGER) ASC, id ASC",
    )
    defer (stmt.finalize() catch { _ => () })
    for {
      if !stmt.step() {
        break
      }
      let content : String = stmt.column(index=4)
      let target_id = if stmt.column_type(index=2) == @sqlite3.SQLITE_NULL {
        None
      } else {
        Some(stmt.column(index=2))
      }
      items.push(
        @db.Message::{
          id: stmt.column(index=0),
          source_id: stmt.column(index=1),
          target_id,
          kind: stmt.column(index=3),
          content,
          timestamp: stmt.column(index=5),
        }.to_json(),
      )
    }
    items.to_json()
  } catch {
    e => {
      log_warn("Failed to load chat messages: \{e}")
      let empty : Array[Json] = []
      empty.to_json()
    }
  }
}
