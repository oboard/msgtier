///|
pub fn Connection::new(
  addr : String,
  conn_id : String,
  is_server : Bool,
) -> Connection {
  { addr, conn_id, is_server, next_packet_number: 0L, streams: {} }
}

///|
pub fn Connection::open_stream(self : Connection) -> Stream {
  let id = self.streams.length().to_int64()
  let stream = { id, offset: 0L, fin: false, incoming_data: b"" }
  self.streams[id] = stream
  stream
}

///|
pub fn Connection::handle_frame(self : Connection, frame : Frame) -> Unit {
  match frame {
    Stream(s) =>
      // Find or create stream
      match self.streams.get(s.stream_id) {
        Some(stream) => {
          stream.incoming_data = stream.incoming_data + s.data
          stream.offset = stream.offset + s.data.length().to_int64()
          if s.fin {
            stream.fin = true
          }
        }
        None => {
          // New stream from remote
          let stream = {
            id: s.stream_id,
            offset: s.data.length().to_int64(),
            fin: s.fin,
            incoming_data: s.data,
          }
          self.streams[s.stream_id] = stream
        }
      }
    _ => ()
  }
}

///|
pub fn Connection::next_packet_number(self : Connection) -> Int64 {
  let pn = self.next_packet_number
  self.next_packet_number = self.next_packet_number + 1L
  pn
}
