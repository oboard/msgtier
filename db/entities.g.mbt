///|
pub impl @oboard/morm.Entity for Message with table(_self) -> @oboard/morm.Table {
  Message::table()
}

///|
pub fn Message::table() -> @morm.Table {
  try! @json.from_json({
    "name": "Message",
    "columns": [
      {
        "name": "id",
        "column_type": ["VarChar", 36],
        "size": 0,
        "nullable": false,
        "auto_increment": false,
        "primary_key": true,
        "unique": false,
        "comment": "",
      },
      {
        "name": "content",
        "column_type": ["VarChar", 255],
        "size": 0,
        "nullable": false,
        "auto_increment": false,
        "primary_key": false,
        "unique": false,
        "comment": "",
      },
      {
        "name": "created_at",
        "column_type": "DateTime",
        "size": 0,
        "nullable": false,
        "auto_increment": false,
        "primary_key": false,
        "unique": false,
        "comment": "",
      },
    ],
    "indexes": [],
    "foreign_keys": [],
    "engine": "InnoDB",
    "charset": "utf8mb4",
    "collation": "utf8mb4_unicode_ci",
    "comment": "",
    "auto_increment": 1,
  })
}
