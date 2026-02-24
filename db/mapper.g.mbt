///|
pub struct MessageMapper_ {
  engine : &@engine.Engine
}

///|
pub fn Message::mapper(engine : &@engine.Engine) -> MessageMapper_ {
  MessageMapper_::{ engine, }
}

///|
pub impl MessageMapper for MessageMapper_ with find_by_peer_id(self) -> FixedArray[
  Message,
] {
  let (sql, params) = @morm.select_from(Message::table().name)
    .where_eq("peer_id", peer_id.to_json())
    .to(self.engine.dialect())
  self.engine.exec(sql, params).rows.map(row => {
    @json.from_json(row) catch {
      _ => panic()
    }
  })
}

///|
pub fn MessageMapper_::save(
  self : MessageMapper_,
  entity : Message,
) -> Message? {
  let (sql, params) = @morm.upsert_into(Message::table().name)
    .from(entity)
    .to(self.engine.dialect())
  let res = self.engine.exec(sql, params)
  if res.rows is [result, ..] {
    return Some(try! @json.from_json(result))
  }
  // Fallback: read back by conflict keys when UPSERT does not return rows
  let tbl = Message::table()
  let obj = if entity.to_json() is Object(obj) { obj } else { {} }
  // try primary key first
  match tbl.primary_key() {
    Some(pk) =>
      match obj.get(pk) {
        Some(pkv) => {
          let (sel_sql, sel_params) = @morm.select_from(tbl.name)
            .where_eq(pk, pkv)
            .to(self.engine.dialect())
          if self.engine.exec(sel_sql, sel_params).rows is [row, ..] {
            return Some(try! @json.from_json(row))
          }
        }
        None => ()
      }
    None => ()
  }
  // try first unique index with all values present
  for idx in tbl.indexes {
    match idx.index_type {
      Unique => {
        let mut q = @morm.select_from(tbl.name)
        let mut ok = true
        for col in idx.columns {
          match obj.get(col) {
            Some(v) => q = q.where_eq(col, v)
            None => {
              ok = false
              break
            }
          }
        }
        if ok {
          let (sel_sql, sel_params) = q.to(self.engine.dialect())
          if self.engine.exec(sel_sql, sel_params).rows is [row, ..] {
            return Some(try! @json.from_json(row))
          }
        }
        break
      }
      _ => ()
    }
  }
  None
}

///|
pub fn MessageMapper_::delete(self : MessageMapper_, entity : Message) -> Bool {
  let primary_key = Message::table().primary_key()
  if primary_key is Some(_) {
    let (sql, params) = @morm.delete_from(Message::table().name)
      .from(entity)
      .to(self.engine.dialect())
    self.engine.exec(sql, params).ok
  } else {
    false
  }
}
