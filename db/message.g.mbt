///|
pub impl @oboard/morm.Entity for Message with table(_self) -> @oboard/morm.Table {
  Message::table()
}

///|
pub fn Message::table() -> @oboard/morm.Table {
  @oboard/morm.Table::{
    name: "message",
    schema: None,
    catalog: None,
    columns: [
      {
        name: "id",
        column_type: VarChar(36),
        size: 0,
        nullable: false,
        auto_increment: false,
        primary_key: true,
        unique: false,
        comment: "",
        charset: None,
        collation: None,
        default_value: None,
        engine_options: [],
      },
      {
        name: "source_id",
        column_type: VarChar(255),
        size: 0,
        nullable: false,
        auto_increment: false,
        primary_key: false,
        unique: false,
        comment: "",
        charset: None,
        collation: None,
        default_value: None,
        engine_options: [],
      },
      {
        name: "target_id",
        column_type: VarChar(255),
        size: 0,
        nullable: true,
        auto_increment: false,
        primary_key: false,
        unique: false,
        comment: "",
        charset: None,
        collation: None,
        default_value: None,
        engine_options: [],
      },
      {
        name: "kind",
        column_type: VarChar(255),
        size: 0,
        nullable: false,
        auto_increment: false,
        primary_key: false,
        unique: false,
        comment: "",
        charset: None,
        collation: None,
        default_value: None,
        engine_options: [],
      },
      {
        name: "content",
        column_type: Text,
        size: 0,
        nullable: false,
        auto_increment: false,
        primary_key: false,
        unique: false,
        comment: "",
        charset: None,
        collation: None,
        default_value: None,
        engine_options: [],
      },
      {
        name: "timestamp",
        column_type: VarChar(255),
        size: 0,
        nullable: false,
        auto_increment: false,
        primary_key: false,
        unique: false,
        comment: "",
        charset: None,
        collation: None,
        default_value: None,
        engine_options: [],
      },
    ],
    indexes: [],
    foreign_keys: [],
    temporary: false,
    if_not_exists: true,
    engine: None,
    charset: None,
    collation: None,
    tablespace: None,
    comment: "",
    auto_increment: None,
    engine_options: [],
  }
}

///|
pub fn Message::_from(row : Map[String, @engine.Param]) -> Message {
  let id_param = match row.get("id") {
    Some(value) => value
    None => panic()
  }
  let id : String = (try! @engine.from_param(id_param) : String)
  let source_id_param = match row.get("source_id") {
    Some(value) => value
    None => panic()
  }
  let source_id : String = (try! @engine.from_param(source_id_param) : String)
  let target_id_param = match row.get("target_id") {
    Some(value) => value
    None => panic()
  }
  let target_id : String? = match target_id_param {
    Null => None
    _ => Some((try! @engine.from_param(target_id_param) : String))
  }
  let kind_param = match row.get("kind") {
    Some(value) => value
    None => panic()
  }
  let kind : String = (try! @engine.from_param(kind_param) : String)
  let content_param = match row.get("content") {
    Some(value) => value
    None => panic()
  }
  let content : String = (try! @engine.from_param(content_param) : String)
  let timestamp_param = match row.get("timestamp") {
    Some(value) => value
    None => panic()
  }
  let timestamp : String = (try! @engine.from_param(timestamp_param) : String)
  return Message::{ id, source_id, target_id, kind, content, timestamp }
}

///|
pub impl @engine.FromParam for Message with from_param(value) {
  match value {
    @engine.Json(Object(obj)) => {
      let row : Map[String, @engine.Param] = Map::new()
      for key in obj.keys() {
        if obj.get(key) is Some(value) {
          row.set(key, @engine.to_param(value))
        }
      }
      Message::_from(row)
    }
    _ =>
      raise @engine.ParamDecodeError(
        "Message::from_param: expected Json object row",
      )
  }
}
