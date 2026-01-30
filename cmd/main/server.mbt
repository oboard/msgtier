///|
struct Message {
  kind : String
  name : String
  addr : String
  peers : Array[String]?
  payload : String?
  target : String?
  data : String?
} derive(Show, ToJson, FromJson)

///|
pub fn message_encode(msg : Message) -> Bytes {
  @utf8.encode(msg.to_json().stringify())
}

///|
pub fn message_decode(bytes : Bytes) -> Message? {
  let text = @utf8.decode_lossy(bytes)
  let json = @json.parse(text) catch { _ => return None }
  let msg = @json.from_json(json) catch { _ => return None }
  Some(msg)
}

///|
pub fn add_peer(peers : Array[String], peer : String) -> Unit {
  if peer.is_empty() {
    return
  }
  for existing in peers {
    if existing == peer {
      return
    }
  }
  peers.push(peer)
}

///|
pub fn merge_peers(peers : Array[String], incoming : Array[String]) -> Unit {
  for peer in incoming {
    add_peer(peers, peer)
  }
}

///|
fn pick_relay_peer(
  peers : Array[String],
  target : String,
  sender : String,
  local_addr : String,
) -> String? {
  for peer in peers {
    if peer != target && peer != sender && peer != local_addr {
      return Some(peer)
    }
  }
  None
}

///|
async fn send_message(
  server : @socket.UdpServer,
  peer : String,
  msg : Message,
) -> Unit {
  if peer.is_empty() {
    return
  }
  try {
    let addr = @socket.Addr::parse(peer)
    server.sendto(message_encode(msg), addr)
  } catch {
    _ => ()
  }
}

///|
async fn listen_udp(
  root : @async.TaskGroup[Unit],
  addr : @socket.Addr,
  name : String,
  peers : Array[String],
) -> Unit {
  let server = @socket.UdpServer::new(addr)
  defer server.close()
  let known_peers : Array[String] = []
  for peer in peers {
    add_peer(known_peers, peer)
  }
  let local_addr = "\{server.addr()}"
  let hello = Message::{
    kind: "hello",
    name,
    addr: local_addr,
    peers: Some(known_peers),
    payload: None,
    target: None,
    data: None,
  }
  for peer in known_peers {
    send_message(server, peer, hello)
  }
  for {
    let buf = FixedArray::make(2048, b'0')
    let (n, sender) = server.recvfrom(buf)
    let bytes = buf.unsafe_reinterpret_as_bytes()[0:n].to_bytes()
    let msg = message_decode(bytes)
    match msg {
      Some(msg) => {
        let sender_addr = "\{sender}"
        add_peer(known_peers, sender_addr)
        match msg.peers {
          Some(peers) => merge_peers(known_peers, peers)
          None => ()
        }
        if !msg.addr.is_empty() {
          add_peer(known_peers, msg.addr)
        }
        match msg.kind {
          "hello" => {
            let reply = Message::{
              kind: "welcome",
              name,
              addr: local_addr,
              peers: Some(known_peers),
              payload: None,
              target: None,
              data: None,
            }
            send_message(server, sender_addr, reply)
          }
          "ping" => {
            let reply = Message::{
              kind: "pong",
              name,
              addr: local_addr,
              peers: None,
              payload: None,
              target: None,
              data: None,
            }
            send_message(server, sender_addr, reply)
          }
          "punch_request" =>
            match msg.target {
              Some(target) => {
                let punch_to_target = Message::{
                  kind: "punch",
                  name,
                  addr: local_addr,
                  peers: None,
                  payload: None,
                  target: Some(sender_addr),
                  data: None,
                }
                let punch_to_sender = Message::{
                  kind: "punch",
                  name,
                  addr: local_addr,
                  peers: None,
                  payload: None,
                  target: Some(target),
                  data: None,
                }
                send_message(server, target, punch_to_target)
                send_message(server, sender_addr, punch_to_sender)
              }
              None => ()
            }
          "punch" =>
            match msg.target {
              Some(target) => {
                let ack_to_target = Message::{
                  kind: "punch_ack",
                  name,
                  addr: local_addr,
                  peers: None,
                  payload: None,
                  target: None,
                  data: None,
                }
                let ack_to_sender = Message::{
                  kind: "punch_ack",
                  name,
                  addr: local_addr,
                  peers: None,
                  payload: None,
                  target: None,
                  data: None,
                }
                send_message(server, target, ack_to_target)
                send_message(server, sender_addr, ack_to_sender)
              }
              None => ()
            }
          "relay" =>
            match msg.target {
              Some(target) =>
                match msg.data {
                  Some(data) => {
                    let forward = Message::{
                      kind: "data",
                      name: msg.name,
                      addr: msg.addr,
                      peers: None,
                      payload: None,
                      target: None,
                      data: Some(data),
                    }
                    send_message(server, target, forward)
                  }
                  None => ()
                }
              None => ()
            }
          "send" =>
            match msg.target {
              Some(target) =>
                match msg.data {
                  Some(data) => {
                    let direct = Message::{
                      kind: "data",
                      name: msg.name,
                      addr: msg.addr,
                      peers: None,
                      payload: None,
                      target: None,
                      data: Some(data),
                    }
                    send_message(server, target, direct)
                    match
                      pick_relay_peer(
                        known_peers, target, sender_addr, local_addr,
                      ) {
                      Some(relay_peer) => {
                        let request = Message::{
                          kind: "punch_request",
                          name,
                          addr: local_addr,
                          peers: None,
                          payload: None,
                          target: Some(target),
                          data: None,
                        }
                        let relay = Message::{
                          kind: "relay",
                          name: msg.name,
                          addr: msg.addr,
                          peers: None,
                          payload: None,
                          target: Some(target),
                          data: Some(data),
                        }
                        send_message(server, relay_peer, request)
                        send_message(server, relay_peer, relay)
                      }
                      None => ()
                    }
                  }
                  None => ()
                }
              None => ()
            }
          "data" => ()
          _ => ()
        }
      }
      None => ()
    }
    root.spawn_bg(fn() {  })
  }
}
