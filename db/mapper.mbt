///|
#morm.mapper(Message)
pub trait MessageMapper {
  find_by_peer_id(Self, String) -> FixedArray[Message]
  find_all(Self) -> FixedArray[Message]
}
