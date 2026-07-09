# MsgTier - Decentralized P2P Messaging Network

MsgTier is a decentralized P2P messaging network written in **MoonBit**. Nodes discover each other over multiple transports (UDP / TCP / WebSocket / QUIC), establish end-to-end encrypted channels, and relay messages through the mesh — no central server required.

## Features

- **Multi-transport** — a single node can listen and dial on UDP, TCP, WebSocket, and QUIC simultaneously.
- **Auto peer discovery** — gossip-based topology sync via `sync`/`ack` messages, seeded from the configured `peers` list.
- **End-to-end encryption** — X25519 ECDH key exchange with symmetric encryption; toggleable per node via `disable_encryption`.
- **Message relay** — intra-network relay through intermediate peers, plus optional cross-network (foreign) relay through public nodes with a configurable BPS limit.
- **Health monitoring** — periodic `ping`/`pong` with automatic disconnect + reconnect.
- **Port forwarding** — expose a peer's local TCP/UDP/HTTP service on your machine, or scan/publish reachable ports across the mesh.
- **HTTP proxy** — proxy arbitrary HTTP requests through a remote peer (`/api/proxy`, `http_proxy` message kind).
- **Channel chat** — LLM-style streamed chat sessions routed through peers (`/api/channels/chat`).
- **Object store** — upload / register / download blobs by ID, retrievable from any connected peer (`/api/object`).
- **Script execution** — trigger named shell scripts on a peer with `POST /api/send` + `kind: script`.
- **Hot reload** — patch runtime config (scripts, forwards, exposes, whitelists…) without restarting via `POST /api/config/hot-reload`.
- **STUN NAT discovery** — probe public reflexive addresses for UDP listeners.
- **Embedded SPA** — a static web UI is compiled into the binary and served at `/`.
- **HTTP REST API** — status, config, send, port scan, port mappings, chat, object endpoints.
- **Cross-platform** — Windows, macOS, Linux; the project prefers native compilation.

## Quick Start

### 1. Configuration

MsgTier reads a JSON5 config file (comments and trailing commas are OK). A minimal `node.json` looks like:

```jsonc
{
  "id": "node-1",
  "secret": "your-network-secret",
  "listeners": [
    "udp://0.0.0.0:5668",
    "tcp://0.0.0.0:5669",
    "ws://0.0.0.0:5670"
    // "quic://0.0.0.0:5671"
  ],
  "peers": [
    "udp://120.25.179.85:10101",
    "tcp://120.25.179.85:10102",
    "ws://120.25.179.85:10103"
  ],
  "web_api": "127.0.0.1:9000",
  "scripts": {
    "check_in": "./config/check_in.sh",
    "bash": "bash",
    "echo": "echo 'echo'"
  },
  "exposes": {
    "llm": "http://socrates-llm-gw.jd.com"
  },
  "relay_network_whitelist": ["*"],
  "relay_all_peer_rpc": true,
  "foreign_relay_bps_limit": 1048576,
  "disable_encryption": false,
  "hot_reload": {
    "enable": true,
    "secret": "optional-hot-reload-secret"
  },
  "upload_dir": "./uploads",
  "metadata": { "region": "cn-north" }
}
```

**Config fields:**

| Field | Type | Purpose |
|-------|------|---------|
| `id` | `String` | Node identifier (must be unique in the network). |
| `secret` | `String` | Shared network secret; peers with different secrets are rejected. |
| `listeners` | `String[]` | URLs to bind (`udp://`, `tcp://`, `ws://`, `quic://`). |
| `peers` | `String[]` | Seed peer URLs for initial discovery. |
| `web_api` | `String?` | Bind address for the HTTP API + SPA. |
| `scripts` | `Map<String,String>?` | Named shell commands the peer may execute when receiving `kind: script`. |
| `exposes` | `Map<String,String>?` | HTTP proxy upstreams a peer allows others to route through. |
| `relay_network_whitelist` | `String[]?` | Which foreign networks may relay through this node. `["*"]` = any. |
| `relay_all_peer_rpc` | `Bool?` | If true, forward every unknown-target RPC to eligible relay peers. |
| `foreign_relay_bps_limit` | `Int?` | Bytes/sec throughput cap for cross-network relay. |
| `disable_encryption` | `Bool?` | Skip payload encryption (debug / trusted network only). |
| `hot_reload.enable` | `Bool?` | Enable `POST /api/config/hot-reload`. Defaults to on. |
| `hot_reload.secret` | `String?` | Required secret for hot-reload requests. |
| `upload_dir` | `String?` | Directory for object-store uploads. |
| `metadata` | `Map<String,String>?` | Free-form node metadata (advertised to peers). |
| `log` | `LogLevel?` | `debug` / `info` / `warn` / `error`. |

Static fields (`id`, `secret`, `peers`, `listeners`, `web_api`, `port`) cannot be hot-reloaded; only the runtime layer above them can.

### 2. Start Nodes

```bash
./msgtier node1.json
./msgtier node2.json
./msgtier node3.json

# or
./msgtier --version
./msgtier --help
```

### 3. Send Messages

```bash
curl --location 'http://localhost:9000/api/send' \
  --header 'target: node-1' \
  --header 'kind: script' \
  --data 'check_in'
```

## Architecture

### Message Kinds

Message types are registered against a central dispatcher in
`cmd/main/message_dispatcher.mbt`, `app_data_handler.mbt`, and
`port_forward_handler.mbt`:

| Kind | Purpose |
|------|---------|
| `hello` | Initial handshake — exchanges public keys, version, and identity. |
| `sync` | Topology snapshot (known peers, addresses). Replaces the old `welcome`. |
| `ack` | Acknowledgement / receipt for `sync` and other RPCs. |
| `ping` / `pong` | Liveness heartbeat (10s cadence). |
| `text` | Plain text message (persisted to chat history). |
| `response` | RPC-style reply matched by `payload` (message id). |
| `script` | Trigger a named shell script on the target peer. |
| `object_get` | Object-store fetch RPC. |
| `http_proxy` | Proxy an HTTP request through a peer. |
| `port_forward_open` / `..._accept` / `..._data` / `..._close` / `..._error` | Tunneled port-forwarding stream. |
| `port_scan_snapshot` / `port_scan_delta` | Publish reachable-ports state to peers. |

Every `Message` also carries: `source_id`, `target_id?`, `relay` depth, a
`visited` path for loop prevention, `timestamp`, `timeout_ms?`, an
`encrypted` flag, a `secret_hash` for network authentication, and an
optional zero-copy `attachment` bytes payload.

### End-to-End Encryption

Each node generates an X25519 keypair on startup. Public keys are exchanged
during `hello`, and both sides derive a shared secret via ECDH — including
a self-shared secret used for loopback (`target == self`). All data
messages default to encrypted; setting `"disable_encryption": true` in
config skips this (see `Config::is_encrypt`). If the shared secret is not
yet negotiated, the sender falls back to unencrypted transmission with a
warning.

```
Sender                          Receiver
   │  hello (pubkey exchange)      │
   ├──────────────────────────────►│
   │◄──── hello reply / sync ──────┤
   │                               │
   │  ECDH → shared secret         │
   │  encrypt payload (msgpack)    │
   ├──────────────────────────────►│
   │                               │  decrypt → dispatch by kind
```

### Peer Discovery

Discovery is gossip-based:

1. On startup the node adds every URL in `config.peers` to the known-peer set.
2. It opens a listener per `config.listeners` entry (UDP/TCP/WS/QUIC), starts STUN probing for UDP listeners, and dials seed peers with `hello`.
3. Peers reply — every new connection triggers a `broadcast_sync`, sending a topology snapshot to all known peers (throttled to avoid storms).
4. Receiving a `sync` merges unknown peers into the local set, then greets them with `hello`.
5. Topology expands organically without central coordination.

```
node1 → peers: [node2]
node2 → peers: [node1, node3]
node3 → peers: [node2]

node1 hellos node2 → node2 syncs {node1, node3} back
node1 hellos node3 (discovered via sync)
All three converge to a fully-connected mesh.
```

### Health Monitoring & Reconnection

- `server_heartbeat.mbt` sends `ping` to every peer connection on a periodic tick.
- Missing `pong` responses past the timeout mark the connection inactive.
- A supervisor loop retries failed listeners every 5s, and unhealthy outbound connections are re-dialed with backoff.
- Query live state at `GET /api/status`.

### Message Routing

`send_message_now_with_route` picks the best route per message:

1. Loopback (`target_id == self`) is handled in-process.
2. Otherwise iterate registered transports, prefer TCP when present.
3. For each candidate transport, gather routes from the connection manager
   plus `pick_peer_address` / `pick_peer_lan_address` (LAN preferred).
4. If direct routes fail and `relay_all_peer_rpc` is on, forward through
   whitelisted relay peers, respecting `foreign_relay_bps_limit`.

Send flow: HTTP handler → encrypt + queue → 100 ms pending-message
processor → route selection → transport → target.

## HTTP API

All endpoints are registered in `register_routes` in
`cmd/main/http_service.mbt`. Below is the currently-served set — the
embedded SPA is served for anything unmatched.

### Core

- `GET /api/status` — Active/inactive connections, peer IDs, versions, addresses.
- `GET /api/config` — Full config (with `static_config` and `hot_config` splits).
- `POST /api/config/hot-reload` — Patch the runtime layer:
  ```bash
  curl -X POST http://127.0.0.1:9000/api/config/hot-reload \
    -H 'Content-Type: application/json' \
    -d '{
      "secret": "optional-hot-reload-secret",
      "config": {
        "scripts": { "chrome": "open /Applications/Google\\ Chrome.app" },
        "forwards": {},
        "exposes": {},
        "hot_reload": { "enable": true, "secret": "next-secret" }
      }
    }'
  ```
  Static fields (`id`, `secret`, `listeners`, `peers`, `web_api`, `port`) are rejected.
- `POST /api/send` — Send a message.
  Headers: `target` (required), `kind` (default `script`; also `text`, `binary`, or any registered kind), `timeout` (ms, default 10000).
  Body: request payload (matched against `scripts[]` when `kind: script`).
- `GET /api/download` — Download an artifact (implementation-specific).

### Proxy & Chat

- `ANY /api/proxy` — Proxy an arbitrary HTTP request through a remote peer.
  Headers: `target`/`peer` (peer id), `path` (upstream path), `timeout`.
- `WS /api/ws` — WebSocket firehose for chat / control messages.
- `GET /api/chat/messages` — Query persisted chat history.
- `POST /api/channels/chat` — Route a chat/LLM request through a peer.
- `POST /api/channels/chat/local` — Same, but forced to execute locally.

### Object Store

- `POST /api/object` — Upload bytes; returns `{id}`.
- `POST /api/object/register` — Register a local file path under a new id.
- `GET /api/object/:id` — Download by id (optional `?filename=` override).

### Port Forwarding & Scanning

- `GET /api/port_scan/local` — Ports open on this host.
- `GET /api/port_scan/peers` — Ports reported by peers.
- `POST /api/port_scan/refresh` — Kick a re-scan.
- `GET /api/port_mappings` — List active forward rules.
- `POST /api/port_mappings` — Create a rule (`{protocol, peer_id, listen_host, listen_port, ...}`).
- `PATCH /api/port_mappings/:id` — Modify a rule.
- `DELETE /api/port_mappings/:id` — Remove a rule.

### Static SPA

- `GET /` / `GET /:path` / `GET /assets/:path` — serve the embedded web UI built into `web/dist.zip`.

## Cross-Platform Script Execution

Scripts are executed via the platform shell:

- **Linux / macOS**: `sh -c "<command>"`
- **Windows**: `cmd.exe /c "<command>"`

Example script map:

```json
"scripts": {
  "browser": "open https://example.com",
  "alert":   "echo Hello",
  "backup":  "./backup.sh"
}
```

## Startup Sequence

`main.mbt` sets everything up inside an `@async.with_task_group`:

1. Parse CLI args (`msgtier <config.json>`, `--version`, `--help`).
2. Load and validate the JSON5 config.
3. Register known peers and initialize port-forward registry, port scanner, foreign-network manager, and port mapping store.
4. For each listener URL: probe STUN (UDP), bind the transport, and enter a retry loop on failure (5s delay).
5. Start the HTTP + WebSocket API on `web_api`.
6. Background tasks run indefinitely: heartbeat, reconnect, pending-message processor, bench-trace flusher.

## Project Layout

```
msgtier/
├── moon.mod                  # module manifest
├── cmd/main/                 # entry point + service code
│   ├── main.mbt              # async task group entry
│   ├── config.mbt            # Config, hot reload, JSON5 parsing
│   ├── message.mbt           # Message struct + msgpack codec
│   ├── message_dispatcher.mbt  # kind → handler registry
│   ├── message_service.mbt   # hello / sync + send_message
│   ├── server*.mbt           # listener supervisor, heartbeat, dispatch
│   ├── crypto.mbt            # X25519 ECDH + symmetric encryption
│   ├── connection_manager.mbt, peer_manager.mbt, route.mbt
│   ├── udp_transport.mbt, tcp_transport.mbt, websocket_transport.mbt, quic_transport.mbt
│   ├── http_service.mbt      # REST + WS routes
│   ├── channel_chat.mbt, chat_history.mbt, chat_store.mbt
│   ├── port_forward_*.mbt, port_scanner*.mbt, port_mapping_store.mbt
│   ├── object_store.mbt, object_http.mbt
│   ├── http_proxy_internal.mbt
│   ├── relay.mbt, foreign_network_manager.mbt
│   ├── stun_discovery.mbt
│   ├── script_executor.mbt
│   └── moon.pkg              # package manifest (target: native)
├── url/                      # WHATWG URL parser (self-contained)
├── msgpack/                  # MessagePack codec
├── x25519/                   # X25519 ECDH
├── nanoid/                   # nanoid string generator
├── quic/                     # QUIC transport primitives
├── stun/                     # STUN client
├── loip/                     # local IP enumeration
├── db/                       # persistence (SQLite via morm)
├── web/                      # embedded static SPA (dist.zip)
├── zipc/                     # zip helpers
├── src/components/           # frontend components
├── config/                   # sample node configs (JSON5)
└── docs/                     # VitePress documentation site
```

## Development

```bash
# One-time
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit

# Everyday
moon fmt        # format
moon check      # lint / type-check (also runs in pre-commit)
moon test       # run tests
moon test --update   # regenerate inspect() snapshots
moon info       # regenerate .mbti public interface files
moon coverage analyze > uncovered.log
```

Before committing:

1. `moon test` — ensure everything is green.
2. `moon info` — regenerate `pkg.generated.mbti` files; review diffs.
3. `moon fmt` — normalize formatting.

## Example: Three-Node Mesh

```bash
# Terminal 1
./msgtier config/1.jsonc
# Terminal 2
./msgtier config/2.json
# Terminal 3
./msgtier config/3.json

# Trigger "check_in" on node-1 from anywhere
curl -X POST 'http://localhost:9000/api/send' \
  -H 'target: node-1' \
  -H 'kind: script' \
  -d 'check_in'
```

Even if node-3 only knows node-2 in its config, it will discover node-1 via
gossip sync and can route messages there directly (or through node-2 if
direct connectivity fails).

## License

Apache-2.0
