///|
#morm.mapper(Message)
pub trait MessageMapper {
  async save(Self, Message) -> Message
  async find_all(Self) -> FixedArray[Message]
}
