///|
struct SyncConnection {
  peer_id : String
  remote_addr : String
  relay : Int
  public_key : Bytes
  latency_ms : Int?
  bandwidth_mbps : Double
  packet_loss_rate : Int

  // New fields to match Connection struct
  id : String
  local_addr : String
  state : String // serialized ConnectionState
  last_seen : UInt64
  quality : Int
  metadata : Map[String, String]?
  latency_history : Array[Int]
  packets_sent : Int
  packets_lost : Int
  bytes_sent : UInt64
  bytes_received : UInt64
  last_ping_time : UInt64?
  version : String
} derive(Show, ToJson)

///|
fn SyncConnection::to_msgpack(self : SyncConnection) -> @msgpack.Value {
  @msgpack.array([
    @msgpack.string(self.peer_id),
    @msgpack.string(self.remote_addr),
    @msgpack.int(self.relay),
    @msgpack.binary(self.public_key),
    match self.latency_ms {
      Some(l) => @msgpack.int(l)
      None => @msgpack.nil()
    },
    @msgpack.float(self.bandwidth_mbps),
    @msgpack.int(self.packet_loss_rate),

    // New fields
    @msgpack.string(self.id),
    @msgpack.string(self.local_addr),
    @msgpack.string(self.state),
    @msgpack.uint64(self.last_seen),
    @msgpack.int(self.quality),
    match self.metadata {
      Some(m) => {
        let map_val = {}
        for k, v in m {
          map_val[k] = @msgpack.string(v)
        }
        @msgpack.map(map_val)
      }
      None => @msgpack.nil()
    },
    @msgpack.array(self.latency_history.map(@msgpack.int)),
    @msgpack.int(self.packets_sent),
    @msgpack.int(self.packets_lost),
    @msgpack.uint64(self.bytes_sent),
    @msgpack.uint64(self.bytes_received),
    match self.last_ping_time {
      Some(t) => @msgpack.uint64(t)
      None => @msgpack.nil()
    },
    @msgpack.string(self.version),
  ])
}

///|
fn SyncConnection::from_msgpack(msgpack : @msgpack.Value) -> SyncConnection? {
  match msgpack {
    Array(
      [
        String(peer_id),
        String(remote_addr),
        Int(relay),
        Binary(public_key),
        latency_val,
        Float(bandwidth_mbps),
        Int(packet_loss_rate),
        String(id),
        String(local_addr),
        String(state),
        UInt64(last_seen),
        Int(quality),
        metadata_val,
        Array(latency_history_val),
        Int(packets_sent),
        Int(packets_lost),
        UInt64(bytes_sent),
        UInt64(bytes_received),
        last_ping_time_val,
        String(version),
      ]
    ) => {
      let latency_ms = match latency_val {
        Int(l) => Some(l)
        _ => None
      }
      let metadata = match metadata_val {
        Map(m) => {
          let map = {}
          for k, v in m {
            match v {
              String(vs) => map[k] = vs
              _ => ()
            }
          }
          Some(map)
        }
        _ => None
      }
      let latency_history = latency_history_val.map(fn(v) {
        match v {
          Int(i) => i
          _ => 0
        }
      })
      let last_ping_time = match last_ping_time_val {
        UInt64(t) => Some(t)
        _ => None
      }
      Some(SyncConnection::{
        peer_id,
        remote_addr,
        relay,
        public_key,
        latency_ms,
        bandwidth_mbps,
        packet_loss_rate,
        id,
        local_addr,
        state,
        last_seen,
        quality,
        metadata,
        latency_history,
        packets_sent,
        packets_lost,
        bytes_sent,
        bytes_received,
        last_ping_time,
        version,
      })
    }
    // Backward compatibility for format without version
    Array(
      [
        String(peer_id),
        String(remote_addr),
        Int(relay),
        Binary(public_key),
        latency_val,
        Float(bandwidth_mbps),
        Int(packet_loss_rate),
        String(id),
        String(local_addr),
        String(state),
        UInt64(last_seen),
        Int(quality),
        metadata_val,
        Array(latency_history_val),
        Int(packets_sent),
        Int(packets_lost),
        UInt64(bytes_sent),
        UInt64(bytes_received),
        last_ping_time_val,
      ]
    ) => {
      let latency_ms = match latency_val {
        Int(l) => Some(l)
        _ => None
      }
      let metadata = match metadata_val {
        Map(m) => {
          let map = {}
          for k, v in m {
            match v {
              String(vs) => map[k] = vs
              _ => ()
            }
          }
          Some(map)
        }
        _ => None
      }
      let latency_history = latency_history_val.map(fn(v) {
        match v {
          Int(i) => i
          _ => 0
        }
      })
      let last_ping_time = match last_ping_time_val {
        UInt64(t) => Some(t)
        _ => None
      }
      Some(SyncConnection::{
        peer_id,
        remote_addr,
        relay,
        public_key,
        latency_ms,
        bandwidth_mbps,
        packet_loss_rate,
        id,
        local_addr,
        state,
        last_seen,
        quality,
        metadata,
        latency_history,
        packets_sent,
        packets_lost,
        bytes_sent,
        bytes_received,
        last_ping_time,
        version: "unknown",
      })
    }
    // Backward compatibility for old format [peer_id, remote_addr, relay, public_key, latency, bandwidth, loss]
    Array(
      [
        String(peer_id),
        String(remote_addr),
        Int(relay),
        Binary(public_key),
        latency_val,
        Float(bandwidth_mbps),
        Int(packet_loss_rate),
      ]
    ) => {
      let latency_ms = match latency_val {
        Int(l) => Some(l)
        _ => None
      }
      Some(SyncConnection::{
        peer_id,
        remote_addr,
        relay,
        public_key,
        latency_ms,
        bandwidth_mbps,
        packet_loss_rate,
        id: "",
        local_addr: "",
        state: "Connected",
        last_seen: 0UL,
        quality: 0,
        metadata: None,
        latency_history: [],
        packets_sent: 0,
        packets_lost: 0,
        bytes_sent: 0UL,
        bytes_received: 0UL,
        last_ping_time: None,
        version: "unknown",
      })
    }
    // Backward compatibility for old format [peer_id, remote_addr, relay, public_key]
    Array(
      [String(peer_id), String(remote_addr), Int(relay), Binary(public_key)]
    ) =>
      Some(SyncConnection::{
        peer_id,
        remote_addr,
        relay,
        public_key,
        latency_ms: None,
        bandwidth_mbps: 0.0,
        packet_loss_rate: 0,
        id: "",
        local_addr: "",
        state: "Connected",
        last_seen: 0UL,
        quality: 0,
        metadata: None,
        latency_history: [],
        packets_sent: 0,
        packets_lost: 0,
        bytes_sent: 0UL,
        bytes_received: 0UL,
        last_ping_time: None,
        version: "unknown",
      })
    // Backward compatibility for old format [peer_id, remote_addr, relay]
    Array([String(peer_id), String(remote_addr), Int(relay)]) =>
      Some(SyncConnection::{
        peer_id,
        remote_addr,
        relay,
        public_key: b"",
        latency_ms: None,
        bandwidth_mbps: 0.0,
        packet_loss_rate: 0,
        id: "",
        local_addr: "",
        state: "Connected",
        last_seen: 0UL,
        quality: 0,
        metadata: None,
        latency_history: [],
        packets_sent: 0,
        packets_lost: 0,
        bytes_sent: 0UL,
        bytes_received: 0UL,
        last_ping_time: None,
        version: "unknown",
      })
    _ => None
  }
}
