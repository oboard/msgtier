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
  let res = self.engine.exec(q)
  if res.rows is [result, ..] {
    return Message::from_row(result)
  }
  panic()
}
