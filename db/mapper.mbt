///|
#morm.mapper(Message)
pub trait MessageMapper {
  async find_by_peer_id(Self, String) -> FixedArray[Message]
  async find_all(Self) -> FixedArray[Message]
}