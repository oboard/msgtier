///|
pub(all) enum Frame {
  Padding
  Ping
  Ack(AckFrame)
  ResetStream(ResetStreamFrame)
  StopSending(StopSendingFrame)
  Crypto(CryptoFrame)
  NewToken(NewTokenFrame)
  Stream(StreamFrame)
  MaxData(Int64)
  MaxStreamData(Int64, Int64)
  ConnectionClose(ConnectionCloseFrame)
  HandshakeDone
} derive(Show, Eq)

///|
pub struct StreamFrame {
  stream_id : Int64
  offset : Int64
  fin : Bool
  data : Bytes
} derive(Show, Eq)

///|
pub struct AckFrame {
  largest_acknowledged : Int64
  delay : Int64
  first_ack_range : Int64
  // ranges : Array[AckRange]
} derive(Show, Eq)

///|
pub struct ResetStreamFrame {
  stream_id : Int64
  error_code : Int64
  final_size : Int64
} derive(Show, Eq)

///|
pub struct StopSendingFrame {
  stream_id : Int64
  error_code : Int64
} derive(Show, Eq)

///|
pub struct CryptoFrame {
  offset : Int64
  data : Bytes
} derive(Show, Eq)

///|
pub struct NewTokenFrame {
  token : Bytes
} derive(Show, Eq)

///|
pub struct ConnectionCloseFrame {
  error_code : Int64
  frame_type : Int64?
  reason_phrase : String
} derive(Show, Eq)
