///|
pub struct MessageMapperImpl {
  engine : &@morm/engine.Engine
}

///|
pub fn MessageMapperImpl::MessageMapperImpl(
  engine : &@morm/engine.Engine,
) -> MessageMapperImpl {
  { engine, }
}

///|
pub impl MessageMapper for MessageMapperImpl with fn save(
  self,
  entity : Message,
) -> Message {
  let q = @morm.upsert_into("message").from(entity)
  let res = self.engine.exec(q)
  if res.rows is [result, ..] {
    return Message::_from(result)
  }
  panic()
}
