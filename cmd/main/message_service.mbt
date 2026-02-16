///|
fn get_identity_info() -> (Bytes, String) {
  let our_public_key = get_public_key()
  let our_secret_hash = match global_config.val {
    Some(config) => bytes_to_hex(hash_secret(config.secret))
    None => abort("No config found")
  }
  (our_public_key, our_secret_hash)
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
  match global_config.val {
    Some(config) => {
      let addrs : Array[NetworkAddress] = []
      let local_ips = get_local_interface_ips()
      // log_info("Local IPs: \{local_ips}")
      for listener_url in config.listeners {
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
fn create_sync_message(my_id : String, local_addr : String) -> Message {
  // Create a message that includes all current connections of this node
  let all_conns = get_global_connection_manager().get_all_connections()
  let connections_data : Array[@msgpack.Value] = []

  // Include direct connections (hops=1)
  for conn in all_conns {
    let elapsed_ms = @env.now() - conn.last_seen
    let bandwidth_mbps = conn.calculate_bandwidth_mbps(elapsed_ms)
    let packet_loss_rate = conn.calculate_packet_loss()
    let updated_conn = Connection::{
      ..conn,
      bandwidth_mbps,
      packet_loss_rate,
      version: conn.version,
    }
    let conn_val = updated_conn.to_msgpack()
    let sync_entry = match conn_val {
      Array(arr) => {
        let pk_bytes = get_global_peer_manager()
          .get_peer(conn.peer_id)
          .map(peer => peer.public_key)
          .unwrap_or([])
        @msgpack.array([..arr, @msgpack.binary(pk_bytes)])
      }
      _ => conn_val
    }
    connections_data.push(sync_entry)
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
  if target_addr.is_empty() {
    return false
  }
  try {
    let msg_to_send = if msg.encrypted {
      match msg.target_id {
        Some(target_id) => {
          let encoded = @msgpack.encode(msg.body)
          let encrypted = encrypt_for_peer(target_id, encoded)
          if encrypted.length() > 0 {
            Message::{
              ..msg,
              body: @msgpack.binary(encrypted),
              encrypted: true,
            }
          } else {
            log_warn("No shared secret for \{target_id}, sending unencrypted")
            Message::{ ..msg, encrypted: false }
          }
        }
        None => {
          log_warn("Encrypted message missing target_id, sending unencrypted")
          Message::{ ..msg, encrypted: false }
        }
      }
    } else {
      msg
    }
    let msgpack_bytes = msg_to_send.to_msgpack()
    transport.send(target_addr, msgpack_bytes)
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
  let (public_key, secret_hash) = get_identity_info()
  let peers_opt = match peers {
    Some(p) => if p.is_empty() { None } else { Some(p) }
    None => None
  }
  Message::new(
    kind="hello",
    source_id=peer_id,
    source_addr=local_addr,
    relay~,
    version=VERSION,
    peers?=peers_opt,
    public_key~,
    secret_hash~,
  )
}
