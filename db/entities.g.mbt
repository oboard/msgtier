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
        column_type: @morm.ColumnType::VarChar(36),
        size: 0,
        nullable: false,
        auto_increment: false,
        primary_key: true,
        unique: false,
        comment: "",
        charset: None,
        collation: None,
        default_value: None,
      },
      {
        name: "content",
        column_type: @morm.ColumnType::VarChar(255),
        size: 0,
        nullable: false,
        auto_increment: false,
        primary_key: false,
        unique: false,
        comment: "",
        charset: None,
        collation: None,
        default_value: None,
      },
      {
        name: "created_at",
        column_type: @morm.ColumnType::DateTime,
        size: 0,
        nullable: false,
        auto_increment: false,
        primary_key: false,
        unique: false,
        comment: "",
        charset: None,
        collation: None,
        default_value: None,
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
