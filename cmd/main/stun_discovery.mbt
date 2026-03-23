///|
struct StunDiscoveryInfo {
  listener : String
  server : String?
  mapped_address : String?
  public_address : String?
  rtt_ms : Int?
  supports_rfc5780 : Bool
  last_error : String?
  updated_at : UInt64
} derive(Show, ToJson, Eq)

///|
let stun_default_servers : Array[String] = [
  "stun.l.google.com:19302",
  "stun1.l.google.com:19302",
  "stun2.l.google.com:19302",
  "stun3.l.google.com:19302",
  "stun4.l.google.com:19302",
  "stun.cloudflare.com:3478",
]

///|
let stun_discovery_state : Map[String, StunDiscoveryInfo] = {}

///|
pub fn get_stun_discovery_snapshot() -> Array[StunDiscoveryInfo] {
  let items : Array[StunDiscoveryInfo] = []
  for _, info in stun_discovery_state {
    items.push(info)
  }
  items
}

///|
fn get_stun_public_addresses(listener : String) -> Array[String] {
  let addrs : Array[String] = []
  match stun_discovery_state.get(listener) {
    Some(info) =>
      match info.public_address {
        Some(addr) => addrs.push(addr)
        None => ()
      }
    None => ()
  }
  addrs
}

///|
async fn probe_listener_stun(listener : String, host : String) -> Unit {
  let probe_transport = match (try? UdpTransport::new(host)) {
    Ok(tp) => tp
    Err(e) => {
      log_warn("STUN probe bind failed for \{listener}: \{e}")
      stun_discovery_state[listener] = StunDiscoveryInfo::{
        listener,
        server: None,
        mapped_address: None,
        public_address: None,
        rtt_ms: None,
        supports_rfc5780: false,
        last_error: Some(e.to_string()),
        updated_at: @env.now(),
      }
      return
    }
  }
  defer probe_transport.server.close()

  let mut last_error = None
  for server in stun_default_servers {
    let server_addr = @stun.resolve_server(server)
    match server_addr {
      Some(addr) => {
        let result = @stun.probe_binding_with_socket(
          probe_transport.server,
          addr,
          1200,
        )
        match result {
          Some(binding) => {
            stun_discovery_state[listener] = StunDiscoveryInfo::{
              listener,
              server: Some(server),
              mapped_address: Some(binding.mapped_address),
              public_address: Some("udp://" + binding.mapped_address),
              rtt_ms: Some(binding.rtt_ms),
              supports_rfc5780: binding.supports_rfc5780,
              last_error: None,
              updated_at: @env.now(),
            }
            return
          }
          None => last_error = Some("STUN binding failed via \{server}")
        }
      }
      None => last_error = Some("STUN server resolve failed: \{server}")
    }
  }

  stun_discovery_state[listener] = StunDiscoveryInfo::{
    listener,
    server: None,
    mapped_address: None,
    public_address: None,
    rtt_ms: None,
    supports_rfc5780: false,
    last_error,
    updated_at: @env.now(),
  }
}
