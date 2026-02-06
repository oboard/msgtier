///|
pub(all) enum PacketType {
  Initial
  Handshake
  ZeroRTT
  OneRTT
  Retry
  VersionNegotiation
} derive(Show, Eq)

///|
pub struct Header {
  first_byte : Byte
  version : UInt? // None for Short Header
  dest_cid : BytesView
  src_cid : BytesView? // None for Short Header
  packet_number : Int64
  payload_length : Int? // None if not present in header
} derive(Show)

///|
pub struct Connection {
  addr : String
  conn_id : String
  is_server : Bool
  mut next_packet_number : Int64
  streams : Map[Int64, Stream]
}

///|
pub struct Stream {
  id : Int64
  mut offset : Int64
  mut fin : Bool
  mut incoming_data : Bytes
} derive(Show)
