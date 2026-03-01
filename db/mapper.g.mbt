///|
pub struct MessageMapperImpl {
  engine : &@engine.Engine
}

///|
pub fn MessageMapperImpl::new(engine : &@engine.Engine) -> MessageMapperImpl {
  MessageMapperImpl::{ engine, }
}

///|
pub impl MessageMapper for MessageMapperImpl with find_by_peer_id(
  self,
  peer_id : String,
) -> FixedArray[Message] {
  let q = @morm.select_from("message").where_eq("peer_id", peer_id)
  @engine.exec_query(self.engine, q).rows.map(row => {
    @json.from_json(row) catch {
      _ => panic()
    }
  })
}

///|
pub impl MessageMapper for MessageMapperImpl with find_all(self) -> FixedArray[
  Message,
] {
  let q = @morm.select_from("message")
  @engine.exec_query(self.engine, q).rows.map(row => {
    @json.from_json(row) catch {
      _ => panic()
    }
  })
}
