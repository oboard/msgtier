///|
pub impl @oboard/morm.Entity for Message with table(_self) -> @oboard/morm.Table {
  Message::table()
}

///|
pub fn Message::table() -> @morm.Table {
  @morm.Table::{
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
pub fn Message::from_row(row : Json) -> Message {
  if row is Object(obj) {
    let id_json = match obj.get("id") {
      Some(value) => value
      None => panic()
    }
    let id : String = (
      try! @engine.from_param(@engine.param_from_json_value(id_json)) : String)
    let source_id_json = match obj.get("source_id") {
      Some(value) => value
      None => panic()
    }
    let source_id : String = (
      try! @engine.from_param(@engine.param_from_json_value(source_id_json)) :
      String)
    let target_id_json = match obj.get("target_id") {
      Some(value) => value
      None => panic()
    }
    let target_id : String? = match target_id_json {
      Null => None
      _ =>
        Some(
          (
            try! @engine.from_param(
              @engine.param_from_json_value(target_id_json),
            ) : String),
        )
    }
    let kind_json = match obj.get("kind") {
      Some(value) => value
      None => panic()
    }
    let kind : String = (
      try! @engine.from_param(@engine.param_from_json_value(kind_json)) : String)
    let content_json = match obj.get("content") {
      Some(value) => value
      None => panic()
    }
    let content : String = (
      try! @engine.from_param(@engine.param_from_json_value(content_json)) :
      String)
    let timestamp_json = match obj.get("timestamp") {
      Some(value) => value
      None => panic()
    }
    let timestamp : String = (
      try! @engine.from_param(@engine.param_from_json_value(timestamp_json)) :
      String)
    return Message::{ id, source_id, target_id, kind, content, timestamp }
  }
  panic()
}
