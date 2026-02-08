// ///|
// struct TcpProxy {
//   listener : @socket.TcpServer
//   local_addr : String
//   target_peer : String
//   target_addr : String // Address within the peer (e.g., "127.0.0.1:80")
// }

// ///|
// impl Show for TcpProxy with output(self, logger) {
//   logger.write_string("TcpProxy { listener: ")
//   logger.write_string(self.listener.addr().to_string())
//   logger.write_string(", local_addr: ")
//   logger.write_string(self.local_addr)
//   logger.write_string(", target_peer: ")
//   logger.write_string(self.target_peer)
//   logger.write_string(", target_addr: ")
//   logger.write_string(self.target_addr)
//   logger.write_string(" }")
// }

// ///|
// // Global map to store active TCP proxies
// let global_tcp_proxies : Ref[Array[TcpProxy]] = Ref::new([])

// ///|
// // Connection ID -> (PeerID, TargetAddr) mapping for tracking responses
// let global_proxy_connections : Ref[Map[String, (String, String)]] = Ref::new({})

// ///|
// // Global map to store active proxy connections (target side)
// // ConnID -> TcpConn
// let global_active_proxy_conns : Map[StringView, @socket.Tcp] = {}

// ///|
// // Global map to store proxy connection sources (target side)
// // ConnID -> SourcePeerID
// let global_proxy_conn_sources : Map[StringView, StringView] = {}

// ///|
// fn add_active_proxy_conn(
//   conn_id : StringView,
//   conn : @socket.Tcp,
//   source_peer : StringView,
// ) -> Unit {
//   global_active_proxy_conns[conn_id] = conn
//   global_proxy_conn_sources[conn_id] = source_peer
// }

// ///|
// fn remove_active_proxy_conn(conn_id : StringView) -> Unit {
//   global_active_proxy_conns.remove(conn_id)
//   global_proxy_conn_sources.remove(conn_id)
// }

// ///|
// // Global map for listener-side connections
// // ConnID -> TcpConn
// let global_listener_proxy_conns : Map[StringView, @socket.Tcp] = {}

// ///|
// fn add_listener_proxy_conn(conn_id : StringView, conn : @socket.Tcp) -> Unit {
//   global_listener_proxy_conns[conn_id] = conn
// }

// ///|
// fn remove_listener_proxy_conn(conn_id : StringView) -> Unit {
//   global_listener_proxy_conns.remove(conn_id)
// }

// ///|
// async fn write_to_proxy_conn(
//   conn_id : StringView,
//   data : Bytes,
// ) -> Unit noraise {
//   // Check if it's a listener-side connection (in global_tcp_proxies closures)
//   // Or target-side connection (in global_active_proxy_conns)

//   // For target-side connections:
//   match global_active_proxy_conns.get(conn_id) {
//     Some(conn) =>
//       conn.write(data) catch {
//         _ => remove_active_proxy_conn(conn_id)
//       }
//     None =>
//       // If not found in target-side, it might be listener-side.
//       match global_listener_proxy_conns.get(conn_id) {
//         Some(conn) =>
//           conn.write(data) catch {
//             _ => remove_listener_proxy_conn(conn_id)
//           }
//         None => log_warn("Unknown proxy connection ID: \{conn_id}")
//       }
//   }
// }

// ///|
// fn close_proxy_conn(conn_id : StringView) -> Unit {
//   match global_active_proxy_conns.get(conn_id) {
//     Some(conn) => {
//       conn.close()
//       remove_active_proxy_conn(conn_id)
//     }
//     None =>
//       match global_listener_proxy_conns.get(conn_id) {
//         Some(conn) => {
//           conn.close()
//           remove_listener_proxy_conn(conn_id)
//         }
//         None => ()
//       }
//   }
// }

// ///|
// async fn start_tcp_proxy(
//   _root : @async.TaskGroup[Unit],
//   listen_addr : String,
//   target_peer : String,
//   target_addr : String,
// ) -> Unit {
//   let addr = @socket.Addr::parse(listen_addr) catch {
//     e => {
//       log_error("Failed to parse listen address \{listen_addr}: \{e}")
//       return
//     }
//   }
//   let listener = @socket.TcpServer::new(addr) catch {
//     e => {
//       log_error("Failed to bind TCP proxy to \{listen_addr}: \{e}")
//       return
//     }
//   }
//   log_info(
//     "Started TCP proxy on \{listen_addr} -> \{target_peer} -> \{target_addr}",
//   )
//   let proxy = TcpProxy::{
//     listener,
//     local_addr: listen_addr,
//     target_peer,
//     target_addr,
//   }
//   global_tcp_proxies.val.push(proxy)
//   log_debug("Created proxy: \{proxy}")
//   listener.run_forever(fn(conn, remote_addr) {
//     let conn_id = @uuidm.v4().to_string()
//     log_info(
//       "New proxy connection \{conn_id} from \{remote_addr} on \{listen_addr}",
//     )

//     // Register connection
//     add_listener_proxy_conn(conn_id, conn)
//     global_proxy_connections.val[conn_id] = (target_peer, target_addr)

//     // Send connect message to target peer
//     let proxy_msg = ProxyMessage::{
//       op: "connect",
//       conn_id,
//       target_addr: Some(target_addr),
//       data: None,
//     }
//     let encoded_bytes = @msgpack.encode(proxy_msg.to_msgpack())
//     let encrypted_bytes = encrypt_for_peer(target_peer, encoded_bytes)
//     let connect_msg = Message::new(
//       kind="data",
//       source_id=get_config().id,
//       source_addr=listen_addr,
//       target=target_peer,
//       data=@msgpack.binary(encrypted_bytes),
//       encrypted=true,
//     )
//     add_pending_message(target_peer, connect_msg)

//     // Read loop
//     try {
//       for {
//         match conn.read_some() {
//           Some(data) => {
//             if data.length() == 0 {
//               break
//             }

//             // Send data message
//             let proxy_msg = ProxyMessage::{
//               op: "data",
//               conn_id,
//               target_addr: Some(target_addr),
//               data: Some(data),
//             }
//             let encoded_bytes = @msgpack.encode(proxy_msg.to_msgpack())
//             let encrypted_bytes = encrypt_for_peer(target_peer, encoded_bytes)
//             let data_msg = Message::new(
//               kind="data",
//               source_id=get_config().id,
//               source_addr=listen_addr,
//               target=target_peer,
//               data=@msgpack.binary(encrypted_bytes),
//               encrypted=true,
//             )
//             add_pending_message(target_peer, data_msg)
//           }
//           None => break
//         }
//       }
//     } catch {
//       _ => ()
//     }

//     // Connection closed
//     log_info("Proxy connection \{conn_id} closed")
//     global_proxy_connections.val.remove(conn_id)
//     remove_listener_proxy_conn(conn_id)

//     // Send close message
//     let proxy_msg = ProxyMessage::{
//       op: "close",
//       conn_id,
//       target_addr: None,
//       data: None,
//     }
//     let encoded_bytes = @msgpack.encode(proxy_msg.to_msgpack())
//     let encrypted_bytes = encrypt_for_peer(target_peer, encoded_bytes)
//     let close_msg = Message::new(
//       kind="data",
//       source_id=get_config().id,
//       source_addr=listen_addr,
//       target=target_peer,
//       data=@msgpack.binary(encrypted_bytes),
//       encrypted=true,
//     )
//     add_pending_message(target_peer, close_msg)
//   })
// }

// ///|
// fn init_tcp_proxies(root : @async.TaskGroup[Unit], config : Config) -> Unit {
//   match config.port {
//     Some(ports) => {
//       log_info("Initializing TCP proxies...")
//       ports.each(fn(listen_addr, target_spec) {
//         log_debug("Processing proxy config: \{listen_addr} -> \{target_spec}")
//         // Strip protocol prefixes from listen address
//         let clean_listen_addr = match @url.Url::parse(listen_addr) {
//           Some(url) => url.get_host()
//           None => listen_addr
//         }

//         // Strip protocol prefixes from target spec
//         let clean_target_spec = match @url.Url::parse(target_spec) {
//           Some(url) => url.get_host()
//           None => target_spec
//         }
//         let parts = clean_target_spec.split(":").to_array()
//         if parts.length() >= 2 {
//           let peer_id = parts[0].to_string()
//           let mut rest = ""
//           for i = 1; i < parts.length(); i = i + 1 {
//             if i > 1 {
//               rest = rest + ":"
//             }
//             rest = rest + parts[i].to_string()
//           }
//           let target_addr = if rest.contains(":") {
//             rest
//           } else {
//             "127.0.0.1:" + rest
//           }
//           let _ : @async.Task[Unit] = root.spawn(fn() {
//             log_info(
//               "Starting TCP proxy on \{clean_listen_addr} for \{peer_id} -> \{target_addr}",
//             )
//             for {
//               log_info(
//                 "Attempting to start TCP proxy on \{clean_listen_addr} for \{peer_id} -> \{target_addr}",
//               )
//               start_tcp_proxy(root, clean_listen_addr, peer_id, target_addr)
//               log_warn(
//                 "TCP proxy on \{clean_listen_addr} stopped unexpectedly. Retrying in 5s...",
//               )
//               @async.sleep(5000)
//             }
//           })

//         } else {
//           log_warn("Invalid target spec for proxy: \{target_spec}")
//         }
//       })
//     }
//     None => log_info("No TCP proxies configured.")
//   }
// }

// ///|
// async fn handle_proxy_message(
//   root : @async.TaskGroup[Unit],
//   local_id : String,
//   local_addr : String,
//   sender_id : String,
//   msg : ProxyMessage,
// ) -> Unit {
//   match msg.op {
//     "connect" =>
//       match msg.target_addr {
//         Some(target_addr) => {
//           log_info(
//             "Proxy connect request: \{msg.conn_id} -> \{target_addr} from \{sender_id}",
//           )
//           try {
//             let addr = @socket.Addr::parse(target_addr)
//             // Use timeout for connection to avoid hanging
//             let conn_res = @async.with_timeout_opt(5000, fn() {
//               @socket.Tcp::connect(addr)
//             })
//             match conn_res {
//               Some(conn) => {
//                 add_active_proxy_conn(msg.conn_id, conn, sender_id)
//                 log_info("Connected to proxy target \{target_addr}")

//                 // Spawn reader
//                 root.spawn(fn() {
//                   try {
//                     for {
//                       match conn.read_some() {
//                         Some(data) => {
//                           if data.length() == 0 {
//                             break
//                           }
//                           let proxy_msg = ProxyMessage::{
//                             op: "data",
//                             conn_id: msg.conn_id,
//                             target_addr: None,
//                             data: Some(data),
//                           }
//                           let encoded = @msgpack.encode(proxy_msg.to_msgpack())
//                           let encrypted = encrypt_for_peer(sender_id, encoded)
//                           let data_msg = Message::new(
//                             kind="data",
//                             source_id=local_id,
//                             source_addr=local_addr,
//                             target=sender_id,
//                             data=@msgpack.binary(encrypted),
//                             encrypted=true,
//                           )
//                           add_pending_message(sender_id, data_msg)
//                         }
//                         None => break
//                       }
//                     }
//                   } catch {
//                     _ => ()
//                   }
//                   // Connection closed
//                   log_info("Proxy target connection closed: \{msg.conn_id}")
//                   let proxy_msg = ProxyMessage::{
//                     op: "close",
//                     conn_id: msg.conn_id,
//                     target_addr: None,
//                     data: None,
//                   }
//                   let encoded = @msgpack.encode(proxy_msg.to_msgpack())
//                   let encrypted = encrypt_for_peer(sender_id, encoded)
//                   let close_msg = Message::new(
//                     kind="data",
//                     source_id=local_id,
//                     source_addr=local_addr,
//                     target=sender_id,
//                     data=@msgpack.binary(encrypted),
//                     encrypted=true,
//                   )
//                   add_pending_message(sender_id, close_msg)
//                   remove_active_proxy_conn(msg.conn_id)
//                 })
//                 |> ignore
//               }
//               None => log_warn("Connect timeout to \{target_addr}")
//             }
//           } catch {
//             e =>
//               log_error(
//                 "Failed to connect to proxy target \{target_addr}: \{e}",
//               )
//           }
//         }
//         None => log_warn("Proxy connect missing target_addr")
//       }
//     "data" => {
//       log_debug(
//         "Received proxy_data for conn_id=\{msg.conn_id} from \{sender_id}",
//       )
//       // Recovery logic
//       match msg.target_addr {
//         Some(target_addr) => {
//           let exists = match global_active_proxy_conns.get(msg.conn_id) {
//             Some(_) => true
//             None =>
//               match global_listener_proxy_conns.get(msg.conn_id) {
//                 Some(_) => true
//                 None => false
//               }
//           }
//           if !exists {
//             log_warn(
//               "Proxy connection \{msg.conn_id} not found, attempting recovery to \{target_addr}",
//             )
//             try {
//               let addr = @socket.Addr::parse(target_addr)
//               let conn = @socket.Tcp::connect(addr)
//               add_active_proxy_conn(msg.conn_id, conn, sender_id)
//               root.spawn(fn() {
//                 try {
//                   for {
//                     match conn.read_some() {
//                       Some(data) => {
//                         if data.length() == 0 {
//                           break
//                         }
//                         let proxy_msg = ProxyMessage::{
//                           op: "data",
//                           conn_id: msg.conn_id,
//                           target_addr: None,
//                           data: Some(data),
//                         }
//                         let encoded = @msgpack.encode(proxy_msg.to_msgpack())
//                         let encrypted = encrypt_for_peer(sender_id, encoded)
//                         let data_msg = Message::new(
//                           kind="data",
//                           source_id=local_id,
//                           source_addr=local_addr,
//                           target=sender_id,
//                           data=@msgpack.binary(encrypted),
//                           encrypted=true,
//                         )
//                         add_pending_message(sender_id, data_msg)
//                       }
//                       None => break
//                     }
//                   }
//                 } catch {
//                   _ => ()
//                 }
//                 let proxy_msg = ProxyMessage::{
//                   op: "close",
//                   conn_id: msg.conn_id,
//                   target_addr: None,
//                   data: None,
//                 }
//                 let encoded = @msgpack.encode(proxy_msg.to_msgpack())
//                 let encrypted = encrypt_for_peer(sender_id, encoded)
//                 let close_msg = Message::new(
//                   kind="data",
//                   source_id=local_id,
//                   source_addr=local_addr,
//                   target=sender_id,
//                   data=@msgpack.binary(encrypted),
//                   encrypted=true,
//                 )
//                 add_pending_message(sender_id, close_msg)
//                 remove_active_proxy_conn(msg.conn_id)
//               })
//               |> ignore
//             } catch {
//               e =>
//                 log_error(
//                   "Failed to recover proxy connection to \{target_addr}: \{e}",
//                 )
//             }
//           }
//         }
//         None => ()
//       }
//       match msg.data {
//         Some(bytes) =>
//           if bytes.length() > 0 {
//             write_to_proxy_conn(msg.conn_id, bytes)
//           } else {
//             log_warn(
//               "Warning: Received empty proxy_data for conn_id=\{msg.conn_id}",
//             )
//           }
//         None => ()
//       }
//     }
//     "close" => {
//       log_info("Proxy connection closed: \{msg.conn_id}")
//       close_proxy_conn(msg.conn_id)
//     }
//     _ => log_warn("Unknown proxy op: \{msg.op}")
//   }
// }
