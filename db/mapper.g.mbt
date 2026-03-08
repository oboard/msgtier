///|
pub struct MessageMapperImpl {
  engine : &@engine.Engine
}

///|
pub fn MessageMapperImpl::new(engine : &@engine.Engine) -> MessageMapperImpl {
  MessageMapperImpl::{ engine, }
}

///|
pub impl MessageMapper for MessageMapperImpl with save(self, entity : Message) -> Message {
  let q = @morm.upsert_into("message").from(entity)
  let res = @engine.exec_query(self.engine, q)
  if res.rows is [result, ..] {
    return Message::from_row(result)
  }
  panic()
}

///|
pub impl MessageMapper for MessageMapperImpl with find_all(self) -> FixedArray[
  Message,
] {
  let q = @morm.select_from("message")
  @engine.exec_query(self.engine, q).rows.map(row => Message::from_row(row))
}
