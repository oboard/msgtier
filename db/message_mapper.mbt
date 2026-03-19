///|
#morm.mapper(table="message")
pub trait MessageMapper {
  async save(Self, Message) -> Message
}
