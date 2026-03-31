///|
async test "quic_integration" {
  // We need an event loop for UdpServer even if we don't run the loop

  let endpoint = Endpoint::new("127.0.0.1:0")

  // Simulate a connection
  let conn = endpoint.connect("127.0.0.1:1234")
  let stream_id = 0L
  let _stream = conn.streams.set(stream_id, {
    id: stream_id,
    offset: 0L,
    fin: false,
    incoming_data: b"",
  })

  // Construct a Stream Frame with data "Hello QUIC"
  let data = b"Hello QUIC"
  let frame = Frame::Stream({ stream_id, offset: 0L, fin: false, data })
  let encoded_frame = encode_frame(frame)

  // Construct Ack Frame
  let ack_frame = Frame::Ack({
    largest_acknowledged: 100L,
    delay: 0L,
    first_ack_range: 0L,
  })
  let encoded_ack = encode_frame(ack_frame)

  // Construct ConnectionClose Frame
  let close_frame = Frame::ConnectionClose({
    error_code: 0L,
    frame_type: None,
    reason_phrase: "Done",
  })
  let encoded_close = encode_frame(close_frame)

  // Mock Header
  let header : Header = {
    first_byte: b'\x40',
    version: None,
    dest_cid: b""[:],
    src_cid: None,
    packet_number: 0L,
    payload_length: None,
  }
  let packet = encode_packet(header, encoded_frame)
  let mut received = false
  endpoint.handle_packet(packet, "127.0.0.1:1234", fn(_c, s) {
    if s.incoming_data == data {
      received = true
    }
  })
  if !received {
    abort("Failed to receive stream data")
  }

  // Test parsing of other frames (just verify they don't crash)
  let _ack_packet = encode_packet(header, encoded_ack)
  endpoint.handle_packet(_ack_packet, "127.0.0.1:1234", fn(_c, _s) { () })
  let _close_packet = encode_packet(header, encoded_close)
  endpoint.handle_packet(_close_packet, "127.0.0.1:1234", fn(_c, _s) { () })

  // ResetStream
  let reset_frame = Frame::ResetStream({
    stream_id: 10L,
    error_code: 5L,
    final_size: 100L,
  })
  let encoded_reset = encode_frame(reset_frame)
  let _reset_packet = encode_packet(header, encoded_reset)
  endpoint.handle_packet(_reset_packet, "127.0.0.1:1234", fn(_c, _s) { () })

  // StopSending
  let stop_frame = Frame::StopSending({ stream_id: 10L, error_code: 5L })
  let encoded_stop = encode_frame(stop_frame)
  let _stop_packet = encode_packet(header, encoded_stop)
  endpoint.handle_packet(_stop_packet, "127.0.0.1:1234", fn(_c, _s) { () })

  // Crypto
  let crypto_frame = Frame::Crypto({ offset: 0L, data: b"Client Hello" })
  let encoded_crypto = encode_frame(crypto_frame)
  let _crypto_packet = encode_packet(header, encoded_crypto)
  endpoint.handle_packet(_crypto_packet, "127.0.0.1:1234", fn(_c, _s) { () })

  // NewToken
  let token_frame = Frame::NewToken({ token: b"token" })
  let encoded_token = encode_frame(token_frame)
  let _token_packet = encode_packet(header, encoded_token)
  endpoint.handle_packet(_token_packet, "127.0.0.1:1234", fn(_c, _s) { () })

  // MaxData
  let max_data_frame = Frame::MaxData(1000L)
  let encoded_max_data = encode_frame(max_data_frame)
  let _max_data_packet = encode_packet(header, encoded_max_data)
  endpoint.handle_packet(_max_data_packet, "127.0.0.1:1234", fn(_c, _s) { () })

  // MaxStreamData
  let max_stream_data_frame = Frame::MaxStreamData(10L, 500L)
  let encoded_max_stream_data = encode_frame(max_stream_data_frame)
  let _max_stream_data_packet = encode_packet(header, encoded_max_stream_data)
  endpoint.handle_packet(_max_stream_data_packet, "127.0.0.1:1234", fn(_c, _s) {
    ()
  })

  // HandshakeDone
  let handshake_done_frame = Frame::HandshakeDone
  let encoded_handshake_done = encode_frame(handshake_done_frame)
  let _handshake_done_packet = encode_packet(header, encoded_handshake_done)
  endpoint.handle_packet(_handshake_done_packet, "127.0.0.1:1234", fn(_c, _s) {
    ()
  })
}

///|
async test "quic_connection_state_persists_across_stream_opens" {
  let endpoint = Endpoint::new("127.0.0.1:0")
  let conn1 = endpoint.connect("127.0.0.1:1234")
  let stream1 = conn1.open_stream()
  endpoint.connections["127.0.0.1:1234"] = conn1

  let conn2 = endpoint.connect("127.0.0.1:1234")
  let stream2 = conn2.open_stream()

  inspect(stream1.id.to_string(), content="0")
  inspect(stream2.id.to_string(), content="1")
}

///|
async test "quic_endpoint_persists_stream_data_across_packets" {
  let endpoint = Endpoint::new("127.0.0.1:0")
  let header : Header = {
    first_byte: b'\x40',
    version: None,
    dest_cid: b""[:],
    src_cid: None,
    packet_number: 0L,
    payload_length: None,
  }
  let frame1 = Frame::Stream({
    stream_id: 0L,
    offset: 0L,
    fin: false,
    data: b"Hello ",
  })
  let frame2 = Frame::Stream({
    stream_id: 0L,
    offset: 6L,
    fin: true,
    data: b"QUIC",
  })
  let packet1 = encode_packet(header, encode_frame(frame1))
  let packet2 = encode_packet(header, encode_frame(frame2))
  let mut received = b""

  endpoint.handle_packet(packet1, "127.0.0.1:1234", fn(_c, s) {
    received = s.incoming_data
  })
  endpoint.handle_packet(packet2, "127.0.0.1:1234", fn(_c, s) {
    received = s.incoming_data
  })

  inspect(received, content="b\"Hello QUIC\"")
}
