///|
fn get_identity_info() -> String {
  match app_state.config {
    Some(config) => bytes_to_hex(hash_secret(config.secret))
    None => abort("No config found")
  }
}

///|
fn get_local_interface_ips() -> Array[String] {
  let ips : Array[String] = []
  let interfaces = @loip.list_interfaces()
  for iface in interfaces {
    if !iface.is_up {
      continue
    }
    for ip in iface.ipv4 {
      let is_loopback = ip == "localhost" || ip.has_prefix("127.")
      if !ip.is_empty() && !is_loopback && !ips.contains(ip) {
        ips.push(ip)
      }
    }
    for ip in iface.ipv6 {
      let is_loopback = ip == "::1" || ip == "0:0:0:0:0:0:0:1"
      let is_link_local = ip.has_prefix("fe80:")
      if !ip.is_empty() && !is_loopback && !is_link_local && !ips.contains(ip) {
        ips.push(ip)
      }
    }
  }
  ips
}

///|
fn get_our_addresses(local_addr : String) -> Array[NetworkAddress] {
  match app_state.config {
    Some(config) => {
      let addrs : Array[NetworkAddress] = []
      let local_ips = get_local_interface_ips()
      // log_info("Local IPs: \{local_ips}")
      for listener_url in config.listeners {
        for stun_addr in get_stun_public_addresses(listener_url) {
          if !addrs.iter().any(fn(a) { a.address == stun_addr }) {
            addrs.push(NetworkAddress::{ address: stun_addr })
          }
        }
        let mut parsed : Address? = None
        try {
          parsed = Some(Address::parse(listener_url))
        } catch {
          _ => ()
        }
        match parsed {
          Some(addr) =>
            if addr.host == "0.0.0.0" {
              if local_ips.is_empty() {
                let addr_str = listener_url.replace(
                  old="0.0.0.0",
                  new="127.0.0.1",
                )
                if !addrs.iter().any(fn(a) { a.address == addr_str }) {
                  addrs.push(NetworkAddress::{ address: addr_str })
                }
              } else {
                for ip in local_ips {
                  let addr_str = Address::new(addr.protocol, ip, addr.port).to_url_string()
                  if !addrs.iter().any(fn(a) { a.address == addr_str }) {
                    addrs.push(NetworkAddress::{ address: addr_str })
                  }
                }
              }
            } else if !addrs.iter().any(fn(a) { a.address == listener_url }) {
              addrs.push(NetworkAddress::{ address: listener_url })
            }
          None => {
            let addr_str = listener_url.replace(old="0.0.0.0", new="127.0.0.1")
            if !addrs.iter().any(fn(a) { a.address == addr_str }) {
              addrs.push(NetworkAddress::{ address: addr_str })
            }
          }
        }
      }
      addrs
    }
    None => {
      let addrs : Array[NetworkAddress] = []
      addrs.push(NetworkAddress::{ address: local_addr })
      addrs
    }
  }
}

///|
fn get_local_node_metadata() -> Map[String, String] {
  match app_state.config {
    Some(config) => {
      let metadata = config.metadata.unwrap_or({})
      let script_names : Array[String] = []
      match config.scripts {
        Some(scripts) =>
          for name, _ in scripts {
            script_names.push(name)
          }
        None => ()
      }
      metadata["scripts"] = script_names.to_json().stringify()
      metadata["channels"] = get_channel_metadata_json()
      metadata["openclaw"] = get_openclaw_metadata_json()
      metadata["port_forwards"] = get_port_forward_metadata_json()
      metadata
    }
    None => {
      let metadata : Map[String, String] = {}
      metadata["scripts"] = "[]"
      metadata["channels"] = "[]"
      metadata["openclaw"] = "[]"
      metadata["port_forwards"] = "[]"
      metadata
    }
  }
}

///|
fn create_sync_message(my_id : String, local_addr : String) -> Message {
  // Create a message that includes all current connections of this node
  let all_conns = get_global_connection_manager().get_all_connections()
  let connections_data : Array[@msgpack.Value] = []
  let local_metadata = get_local_node_metadata()

  // Include direct connections (hops=1)
  for conn in all_conns {
    let elapsed_ms = @env.now() - conn.last_seen
    let bandwidth_mbps = conn.calculate_bandwidth_mbps(elapsed_ms)
    let packet_loss_rate = conn.calculate_packet_loss()
    let updated_conn = Connection::{
      ..conn,
      bandwidth_mbps,
      packet_loss_rate,
      metadata: Some(local_metadata),
      version: conn.version,
    }
    let conn_val = updated_conn.to_msgpack()
    connections_data.push(conn_val)
  }
  Message::new(
    kind="sync",
    source_id=my_id,
    source_addr=local_addr,
    relay=1,
    body=@msgpack.array(connections_data),
  )
}

///|
async fn send_message(
  transport : &Transport,
  target_addr : String,
  msg : Message,
) -> Bool noraise {
  // Check if message is expired
  let now = @env.now()
  let timeout = msg.timeout_ms.unwrap_or(30000U)
  let timeout_u64 = timeout.to_uint64()
  if now > msg.timestamp && now - msg.timestamp > timeout_u64 {
    log_debug(
      "send_message: dropped expired message \{msg.id} (age: \{now - msg.timestamp}ms)",
    )
    remove_pending_message(msg) |> ignore
    return false
  }

  if target_addr.is_empty() {
    return false
  }
  try {
    let msg_to_send = if msg.encrypted {
      let encoded = @msgpack.encode(msg.body)
      let encrypted = encrypt_with_message_key(msg.id, encoded)
      if encrypted.length() > 0 {
        Message::{ ..msg, body: @msgpack.binary(encrypted), encrypted: true }
      } else {
        log_warn("Encryption failed for \{msg.id}, sending unencrypted")
        Message::{ ..msg, encrypted: false }
      }
    } else {
      msg
    }
    let msgpack_bytes = msg_to_send.to_msgpack()
    let msgpack_len = msgpack_bytes.length()
    let attachment_len = match msg.attachment {
      Some(a) => a.length()
      None => 0
    }
    let total_len = 4 + msgpack_len + attachment_len
    let payload_arr = FixedArray::make(total_len, b'\x00')

    // Write MsgPack Len (Big Endian)
    payload_arr[0] = (msgpack_len >> 24).to_byte()
    payload_arr[1] = (msgpack_len >> 16).to_byte()
    payload_arr[2] = (msgpack_len >> 8).to_byte()
    payload_arr[3] = msgpack_len.to_byte()

    // Copy MsgPack Bytes
    for i = 0; i < msgpack_len; i = i + 1 {
      payload_arr[4 + i] = msgpack_bytes[i]
    }

    // Copy Attachment Bytes
    match msg.attachment {
      Some(a) =>
        for i = 0; i < attachment_len; i = i + 1 {
          payload_arr[4 + msgpack_len + i] = a[i]
        }
      None => ()
    }

    // log_debug("DEBUG: send_message id=\{msg.id} total_len=\{total_len} msgpack_len=\{msgpack_len} attachment_len=\{attachment_len} payload_0=\{payload_arr[0].to_int()}")

    transport.send(target_addr, payload_arr.unsafe_reinterpret_as_bytes())
  } catch {
    _ => {
      log_warn("Failed to send message to \{target_addr}")
      false
    }
  }
}

///|
fn create_hello_message(
  peer_id : String,
  local_addr : String,
  relay : Int,
  peers? : Array[NetworkAddress],
) -> Message {
  let secret_hash = get_identity_info()
  let peers_opt = match peers {
    Some(p) => if p.is_empty() { None } else { Some(p) }
    None => None
  }
  Message::new(
    kind="hello",
    source_id=peer_id,
    source_addr=local_addr,
    relay~,
    version=app_state.version,
    peers?=peers_opt,
    secret_hash~,
  )
}
