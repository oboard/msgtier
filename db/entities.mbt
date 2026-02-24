///|
#morm.entity
pub(all) struct Message {
  #morm.primary_key
  #morm.uuid
  id : String
  #morm.varchar(length="255")
  content : String
  #morm.datetime
  created_at : String
} derive(ToJson, FromJson)