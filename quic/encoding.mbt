///|
pub fn encode_packet(header : Header, payload : Bytes) -> Bytes {
  let buf = @buffer.new()
  buf.write_byte(header.first_byte)
  match header.version {
    Some(v) => {
      // Long Header
      // Write Version (4 bytes)
      buf.write_byte(((v >> 24) & 0xFFU).to_byte())
      buf.write_byte(((v >> 16) & 0xFFU).to_byte())
      buf.write_byte(((v >> 8) & 0xFFU).to_byte())
      buf.write_byte((v & 0xFFU).to_byte())

      // Write DCID Len (1 byte)
      let dcid_len = header.dest_cid.length()
      buf.write_byte(dcid_len.to_byte())
      // Write DCID
      for i = 0; i < dcid_len; i = i + 1 {
        buf.write_byte(header.dest_cid[i])
      }

      // Write SCID Len (1 byte)
      let scid_len = match header.src_cid {
        Some(s) => s.length()
        None => 0
      }
      buf.write_byte(scid_len.to_byte())
      // Write SCID
      match header.src_cid {
        Some(s) =>
          for i = 0; i < scid_len; i = i + 1 {
            buf.write_byte(s[i])
          }
        None => ()
      }
    }
    None =>
      // Short Header
      // Just first byte (already written)
      ()
  }
  buf.write_bytes(payload)
  buf.to_bytes()
}

///|
pub fn encode_frame(frame : Frame) -> Bytes {
  let buf = @buffer.new()
  match frame {
    Stream(s) => {
      // Type (1 byte) + Stream ID (8 bytes) + Offset (8 bytes) + Length (8 bytes) + Data
      buf.write_byte(b'\x08')

      // Write Stream ID
      buf.write_int64_be(s.stream_id)
      // Write Offset
      buf.write_int64_be(s.offset)
      // Write Length
      buf.write_int64_be(s.data.length().to_int64())

      // Copy data
      buf.write_bytes(s.data)
    }
    Ack(a) => {
      // Type(0x02) + Largest(8) + Delay(8) + FirstRange(8)
      buf.write_byte(b'\x02')
      buf.write_int64_be(a.largest_acknowledged)
      buf.write_int64_be(a.delay)
      buf.write_int64_be(a.first_ack_range)
    }
    ConnectionClose(c) => {
      // Type(0x1c) + Error(8) + FrameType(8 or 0) + PhraseLen(8) + Phrase
      let phrase_buf = @buffer.new()
      phrase_buf.write_string(c.reason_phrase)
      let phrase_bytes = phrase_buf.to_bytes()
      buf.write_byte(b'\x1c')
      buf.write_int64_be(c.error_code)
      let ft = match c.frame_type {
        Some(t) => t
        None => 0L
      }
      buf.write_int64_be(ft)
      buf.write_int64_be(phrase_bytes.length().to_int64())
      buf.write_bytes(phrase_bytes)
    }
    ResetStream(r) => {
      // Type(0x04) + StreamID(8) + ErrorCode(8) + FinalSize(8)
      buf.write_byte(b'\x04')
      buf.write_int64_be(r.stream_id)
      buf.write_int64_be(r.error_code)
      buf.write_int64_be(r.final_size)
    }
    StopSending(s) => {
      // Type(0x05) + StreamID(8) + ErrorCode(8)
      buf.write_byte(b'\x05')
      buf.write_int64_be(s.stream_id)
      buf.write_int64_be(s.error_code)
    }
    Crypto(c) => {
      // Type(0x06) + Offset(8) + Length(8) + Data
      buf.write_byte(b'\x06')
      buf.write_int64_be(c.offset)
      buf.write_int64_be(c.data.length().to_int64())
      buf.write_bytes(c.data)
    }
    NewToken(t) => {
      // Type(0x07) + Length(8) + Token
      buf.write_byte(b'\x07')
      buf.write_int64_be(t.token.length().to_int64())
      buf.write_bytes(t.token)
    }
    MaxData(max) => {
      // Type(0x10) + MaxData(8)
      buf.write_byte(b'\x10')
      buf.write_int64_be(max)
    }
    MaxStreamData(id, max) => {
      // Type(0x11) + StreamID(8) + MaxData(8)
      buf.write_byte(b'\x11')
      buf.write_int64_be(id)
      buf.write_int64_be(max)
    }
    HandshakeDone =>
      // Type(0x1e)
      buf.write_byte(b'\x1e')
    _ => ()
  }
  buf.to_bytes()
}
