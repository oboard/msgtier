///|
#morm.mapper(table="message")
pub trait MessageMapper {
  async fn save(Self, Message) -> Message
}
