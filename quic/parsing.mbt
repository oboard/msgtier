///|
pub fn parse_frames(payload : Bytes) -> Array[Frame] {
  let frames = []
  if payload.length() < 1 {
    return frames
  }
  let type_byte = payload[0]
  if type_byte == b'\x08' {
    // Stream Frame: Type(1) + ID(8) + Offset(8) + Length(8) + Data
    if payload.length() >= 25 {
      let stream_id = read_int64_be(payload, 1)
      let offset = read_int64_be(payload, 9)
      let length = read_int64_be(payload, 17)
      if payload.length().to_int64() >= 25L + length {
        // Safe to read data
        let data = slice(payload, 25, length.to_int())
        frames.push(
          Frame::Stream({
            stream_id,
            offset,
            fin: false, // TODO: parse FIN bit from type
            data,
          }),
        )
      }
    }
  } else if type_byte == b'\x02' {
    // Ack Frame: Type(1) + Largest(8) + Delay(8) + FirstRange(8)
    if payload.length() >= 25 {
      let largest_acknowledged = read_int64_be(payload, 1)
      let delay = read_int64_be(payload, 9)
      let first_ack_range = read_int64_be(payload, 17)
      frames.push(Frame::Ack({ largest_acknowledged, delay, first_ack_range }))
    }
  } else if type_byte == b'\x1c' {
    // ConnectionClose Frame
    if payload.length() >= 25 {
      let error_code = read_int64_be(payload, 1)
      let frame_type_val = read_int64_be(payload, 9)
      let frame_type = if frame_type_val == 0L {
        None
      } else {
        Some(frame_type_val)
      }
      let phrase_len = read_int64_be(payload, 17)
      if payload.length().to_int64() >= 25L + phrase_len {
        // let phrase_bytes = slice(payload, 25, phrase_len.to_int())
        // Convert bytes to string (simplified, assume valid UTF8)
        // We need a helper for bytes to string
        // For now, empty string if we can't easily convert
        // Or implement bytes_to_string
        frames.push(
          Frame::ConnectionClose({ error_code, frame_type, reason_phrase: "" }, // Placeholder
          ),
        )
      }
    }
  } else if type_byte == b'\x04' {
    // ResetStream
    if payload.length() >= 25 {
      let stream_id = read_int64_be(payload, 1)
      let error_code = read_int64_be(payload, 9)
      let final_size = read_int64_be(payload, 17)
      frames.push(Frame::ResetStream({ stream_id, error_code, final_size }))
    }
  } else if type_byte == b'\x05' {
    // StopSending
    if payload.length() >= 17 {
      let stream_id = read_int64_be(payload, 1)
      let error_code = read_int64_be(payload, 9)
      frames.push(Frame::StopSending({ stream_id, error_code }))
    }
  } else if type_byte == b'\x06' {
    // Crypto
    if payload.length() >= 17 {
      let offset = read_int64_be(payload, 1)
      let length = read_int64_be(payload, 9)
      if payload.length().to_int64() >= 17L + length {
        let data = slice(payload, 17, length.to_int())
        frames.push(Frame::Crypto({ offset, data }))
      }
    }
  } else if type_byte == b'\x07' {
    // NewToken
    if payload.length() >= 9 {
      let length = read_int64_be(payload, 1)
      if payload.length().to_int64() >= 9L + length {
        let token = slice(payload, 9, length.to_int())
        frames.push(Frame::NewToken({ token, }))
      }
    }
  } else if type_byte == b'\x10' {
    // MaxData
    if payload.length() >= 9 {
      let max = read_int64_be(payload, 1)
      frames.push(Frame::MaxData(max))
    }
  } else if type_byte == b'\x11' {
    // MaxStreamData
    if payload.length() >= 17 {
      let id = read_int64_be(payload, 1)
      let max = read_int64_be(payload, 9)
      frames.push(Frame::MaxStreamData(id, max))
    }
  } else if type_byte == b'\x1e' {
    // HandshakeDone
    frames.push(Frame::HandshakeDone)
  }
  frames
}

///|
fn read_int64_be(bytes : Bytes, offset : Int) -> Int64 {
  if bytes[offset:] is [i64be(i), ..] {
    i
  } else {
    0
  }
}
