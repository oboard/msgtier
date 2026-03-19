///|
#morm.entity
pub(all) struct Message {
  #morm.id
  #morm.uuid
  id : String
  #morm.varchar(length="255")
  source_id : String
  #morm.varchar(length="255")
  target_id : String?
  #morm.varchar(length="32")
  kind : String
  #morm.text
  content : String
  #morm.varchar(length="32")
  timestamp : String
} derive(ToJson, FromJson)
