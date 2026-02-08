///|
fn get_identity_info() -> (Bytes, String) {
  let our_public_key = get_public_key()
  let our_secret_hash = match global_config.val {
    Some(config) => hash_secret(config.secret)
    None => abort("No config found")
  }
  (our_public_key, our_secret_hash)
}

///|
fn get_our_addresses(local_addr : String) -> Array[NetworkAddress] {
  match global_config.val {
    Some(config) => {
      let addrs : Array[NetworkAddress] = []
      for listener_url in config.listeners {
        let addr_str = listener_url.replace(old="0.0.0.0", new="127.0.0.1")
        addrs.push(NetworkAddress::{ address: addr_str })
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
  let all_peers = get_global_peer_manager().get_all_peers()
  let all_conns = get_global_connection_manager().get_all_connections()
  let connections_data : Array[@msgpack.Value] = []

  // Include direct connections (hops=1)
  for peer in all_peers {
    let peer_conns = peer.get_all_connections(all_conns)
    for conn in peer_conns {
      let pk = peer.public_key
      let elapsed_ms = @env.now() - conn.last_seen
      let bandwidth_mbps = conn.calculate_bandwidth_mbps(elapsed_ms)
      let packet_loss_rate = conn.calculate_packet_loss()
      let sync_conn = SyncConnection::{
        peer_id: peer.id,
        remote_addr: conn.remote_addr,
        relay: conn.relay,
        public_key: pk,
        latency_ms: conn.latency_ms,
        bandwidth_mbps,
        packet_loss_rate,
        id: conn.id,
        protocol: conn.protocol,
        local_addr: conn.local_addr,
        last_seen: conn.last_seen,
        quality: conn.quality,
        metadata: conn.metadata,
        latency_history: conn.latency_history,
        packets_sent: conn.packets_sent,
        packets_lost: conn.packets_lost,
        bytes_sent: conn.bytes_sent,
        bytes_received: conn.bytes_received,
        last_ping_time: conn.last_ping_time,
        version: peer.version,
        nat_type: conn.nat_type,
      }
      connections_data.push(sync_conn.to_msgpack())
    }
  }

  // Include known routes (hops > 1)
  let all_routes = get_global_peer_manager().get_all_routes()
  for peer_id, route in all_routes {
    // Only advertise routes that are NOT direct connections (to avoid duplication)
    // and valid routes
    if route.hops > 1 {
      match get_global_peer_manager().get_peer(peer_id) {
        Some(peer) => {
          let pk = peer.public_key
          let sync_conn = SyncConnection::{
            peer_id,
            remote_addr: "routed",
            relay: route.hops,
            public_key: pk,
            latency_ms: None,
            bandwidth_mbps: 0.0,
            packet_loss_rate: 0,
            id: "",
            protocol: "",
            local_addr: "",
            last_seen: route.timestamp,
            quality: 0,
            metadata: None,
            latency_history: [],
            packets_sent: 0,
            packets_lost: 0,
            bytes_sent: 0,
            bytes_received: 0,
            last_ping_time: None,
            version: peer.version,
            nat_type: Unknown,
          }
          connections_data.push(sync_conn.to_msgpack())
        }
        None => ()
      }
    }
  }
  Message::new(
    kind="sync",
    from=my_id,
    addr=local_addr,
    relay=1,
    broadcast=true,
    data=@msgpack.array(connections_data),
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
    let msgpack_bytes = msg.to_msgpack()
    transport.send(target_addr, msgpack_bytes)
  } catch {
    _ => {
      println("Failed to send message to \{target_addr}")
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
  session_id? : String,
) -> Message {
  let (public_key, secret_hash) = get_identity_info()
  let peers_opt = match peers {
    Some(p) => if p.is_empty() { None } else { Some(p) }
    None => None
  }
  Message::new(
    kind="hello",
    from=peer_id,
    addr=local_addr,
    relay~,
    version=VERSION,
    peers?=peers_opt,
    public_key~,
    secret_hash~,
    session_id?,
  )
}

///|
// Try sending to both primary and fallback addresses (UDP fire-and-forget)
// We send to both because UDP doesn't guarantee delivery anyway
async fn send_message_with_fallback(
  transport : &Transport,
  primary_addr : String,
  fallback_addr : String,
  msg : Message,
) -> Unit noraise {
  let protocol = transport.protocol()

  // Try primary address - fire and forget
  if !primary_addr.is_empty() {
    // Check protocol compatibility
    let compatible = !primary_addr.contains("://") ||
      primary_addr.has_prefix(protocol + "://")
    if compatible {
      try {
        let msgpack_bytes = msg.to_msgpack()
        transport.send(primary_addr, msgpack_bytes) |> ignore
        println("Sent to primary \{primary_addr}")
      } catch {
        _ => println("Failed to send to primary \{primary_addr}")
      }
    }
  }

  // Try fallback address - fire and forget
  if !fallback_addr.is_empty() && fallback_addr != primary_addr {
    // Check protocol compatibility
    let compatible = !fallback_addr.contains("://") ||
      fallback_addr.has_prefix(protocol + "://")
    if compatible {
      try {
        let msgpack_bytes = msg.to_msgpack()
        transport.send(fallback_addr, msgpack_bytes) |> ignore
        println("Sent to fallback \{fallback_addr}")
      } catch {
        _ => println("Failed to send to fallback \{fallback_addr}")
      }
    }
  }
}
