# Port Mapping Redesign

**Status:** Draft
**Date:** 2026-07-08
**Owner:** oboard

## Motivation

The current port-forwarding subsystem in `msgtier` requires each node to declare all forwarding and exposing rules ahead of time in its `config.json` under `forwards` / `exposes`. This forces users to hand-edit configuration, restart or hot-reload the node, and coordinate node IDs and port numbers out-of-band — none of which fits the "just pull that service down to my box" experience users actually want.

The redesign replaces static configuration with a live network view:

1. Every node continuously discovers what TCP/UDP ports it is locally listening on and broadcasts that list to its peers.
2. Peers store an aggregate view of "what services do I know about across the mesh".
3. The Web UI lets a user pick any remote service and pull it to a local port on their own machine, creating a runtime forwarding rule that survives restarts.

The existing wire messages (`port_forward_open/data/close/error/open_ack`) are proven, cheap to reuse, and stay unchanged.

## Non-Goals

- Building the actual Vue components. This spec defines the HTTP API contract the UI will consume; a follow-up spec will handle UI polish.
- Windows support in the first cut. Design leaves room for a `netstat -ano` backend, but implementation targets macOS/Linux via `lsof`.
- ACL / RBAC. Every connected peer sees every scanned local port. This matches the "trusted mesh" posture the project uses today.
- Rewriting the audit / rate-limit machinery. Reused as-is.

## Requirements

### Functional

1. Each node scans local TCP + UDP listening ports every 30 s and on demand (WebUI refresh, new peer connection).
2. The first message to each freshly-connected peer is a full snapshot; steady-state traffic is deltas only.
3. Each entry carries `(protocol, bind_addr, port, process_name?)` where `process_name` is best-effort.
4. Nodes maintain a peer→ports registry populated from received snapshots and deltas.
5. The WebUI can:
   - list local scanned ports,
   - list ports reported by every peer,
   - trigger an immediate re-scan / re-broadcast,
   - create a local forwarding mapping `local_host:local_port → peer_id via remote_host:remote_port/protocol`,
   - list / toggle / delete existing mappings.
6. Mappings persist across restarts in a dedicated JSON file and are auto-started on boot.
7. Auto-allocation of `local_port` is offered (`target_port + 40000` with fallback), but the user may specify a port explicitly.

### Non-functional

1. **No new dependency on privilege.** `lsof` is invoked without sudo; process names are optional.
2. **Bounded message size.** A delta message is at most O(number-of-changed-ports); a snapshot is O(number-of-local-listeners) which is bounded by the machine's port count.
3. **No polling on the receive side.** Peer ports are updated event-driven from message handlers.
4. **Zero effect on the transport layer.** All new messages route through the existing message dispatcher and honor relay / encryption.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│ msgtier node                                                     │
│                                                                  │
│  ┌────────────────┐  scan every 30s     ┌───────────────────┐    │
│  │ port_scanner   │ ──── diff ────────▶ │ broadcast layer   │    │
│  │  (lsof/netstat)│                     │ port_scan_delta / │    │
│  └────────────────┘                     │ port_scan_snapshot│    │
│         ▲                               └────────┬──────────┘    │
│         │ on refresh / new peer                  │               │
│         │                                        ▼               │
│         │                            ┌───────────────────────┐   │
│         │                            │ message dispatcher    │   │
│         │                            │ (existing plumbing)   │   │
│         │                            └────┬──────────────┬───┘   │
│         │                                 │              │       │
│  ┌──────┴───────────┐  handler   ◀────────┘              │       │
│  │ remote_port_     │                                    │       │
│  │ registry         │                                    │       │
│  │  (per-peer map)  │                                    │       │
│  └──────────────────┘                                    │       │
│         ▲                                                │       │
│  ┌──────┴─────────────┐                                  │       │
│  │ HTTP API layer     │  POST /api/port_mappings         │       │
│  │  /api/port_scan/…  │ ─────────────────┐               │       │
│  │  /api/port_mappings│                  ▼               │       │
│  └────────────────────┘   ┌─────────────────────────┐    │       │
│                           │ port_mapping_store      │    │       │
│                           │  ~/.msgtier/            │    │       │
│                           │   port_mappings.json    │    │       │
│                           └────────────┬────────────┘    │       │
│                                        │ on load / mutate│       │
│                                        ▼                 │       │
│                        ┌───────────────────────────────┐ │       │
│                        │ port_forward_runtime          │◀┘       │
│                        │  (existing tcp/udp listeners) │         │
│                        └───────────────────────────────┘         │
└──────────────────────────────────────────────────────────────────┘
```

### Modules

| Module | File(s) | Responsibility |
|---|---|---|
| Local scanner | `cmd/main/port_scanner.mbt` | Invoke `lsof`, parse output, diff previous scan, filter self-listeners. |
| Wire protocol | `cmd/main/port_forward_messages.mbt` (extend) | Add `port_scan_snapshot` and `port_scan_delta` message body builders/parsers. |
| Broadcast + scheduler | `cmd/main/port_scanner.mbt` | 30 s poll task + refresh trigger + broadcast to peers + snapshot on new-peer event. |
| Remote registry | `cmd/main/port_scanner.mbt` | `ports_by_peer : Map[String, Array[LocalPortEntry]]` populated from handlers. |
| Handlers | `cmd/main/port_forward_handler.mbt` (extend) | Register handlers for the two new message types. |
| Mapping store | `cmd/main/port_mapping_store.mbt` (new) | JSON persistence and runtime `PortForwardForwardRule` synthesis. |
| HTTP API | `cmd/main/http_service.mbt` (extend) + new dedicated handler file | Expose scan and mapping endpoints. |
| Config cleanup | `cmd/main/config.mbt`, `port_forward_config.mbt` | Delete `forwards`, `exposes`, associated parse/serialize/expose-rule code. |

## Data Model

### `LocalPortEntry`

```
struct LocalPortEntry {
  protocol : String        // "tcp" | "udp"
  bind_addr : String       // "0.0.0.0" | "127.0.0.1" | "::" | ...
  port : Int
  process_name : String?
} derive(Debug, Eq, ToJson, FromJson)
```

Sort order for stable diffing: `(protocol, port, bind_addr, process_name.unwrap_or(""))`.

### `PortMapping` (persisted)

```
struct PortMapping {
  id : String              // nanoid, stable across restarts
  peer_id : String
  remote_protocol : String // "tcp" | "udp"
  remote_host : String     // usually "127.0.0.1" — that's the peer's local view
  remote_port : Int
  local_host : String      // default "127.0.0.1"
  local_port : Int
  enabled : Bool
  created_at : UInt64      // ms since epoch
  note : String?
} derive(Debug, ToJson, FromJson)
```

### Persistence file

Path resolution (first hit wins):

1. `${config.upload_dir}/../port_mappings.json` when `upload_dir` is set (colocate with data)
2. `${state_home}/msgtier/port_mappings.json` where `state_home` = `$XDG_STATE_HOME` or `$HOME/.local/state` on Linux, `$HOME/Library/Application Support` on macOS, `$LOCALAPPDATA` on Windows
3. Fallback: `${cwd}/port_mappings.json`

Format:

```json
{
  "version": 1,
  "mappings": [ { ... PortMapping ... } ]
}
```

The file is written atomically (temp file + rename) after every mutation. If read fails at boot, the store starts empty and logs a warning — the runtime is never blocked by a bad file.

## Wire Protocol

Reuses the msgpack-body / attachment convention already established by `port_forward_*` messages. Both new kinds are broadcast/unicast to a single peer; there is no `attachment`.

### `port_scan_snapshot`

Full state, sent once when a peer becomes reachable (from either side) or on WebUI-triggered refresh:

```
body: {
  "version": 1,
  "ports": [
    { "protocol": "tcp", "bind_addr": "127.0.0.1", "port": 5432, "process_name": "postgres" },
    ...
  ]
}
```

### `port_scan_delta`

Delta sent whenever the scheduled scan detects a change:

```
body: {
  "version": 1,
  "added":   [ LocalPortEntry, ... ],
  "removed": [ LocalPortEntry, ... ]
}
```

On the receive side, snapshot replaces the entry for that peer; delta applies `added ∪ (curr \ removed)` and updates `last_updated`.

Malformed messages are logged and dropped — never crash the dispatcher.

## Scanning

**Trigger sources** (any one can fire a scan):

1. Startup — first scan immediately, then schedule.
2. Every 30 s via a `root.spawn_bg` timer.
3. WebUI: `POST /api/port_scan/refresh` (see API).
4. Peer manager: on `peer_manager.on_peer_connected` (or equivalent hook — check current API).

Trigger 4 sends the *current* snapshot to that peer only, without re-scanning. Triggers 1–3 re-scan, diff against `last_scan`, and broadcast the delta to every known peer. If `last_scan` is empty (first scan), a full snapshot is sent to every peer.

**Scanner backends** (dispatched on platform):

- macOS + Linux: `lsof -nP -iTCP -sTCP:LISTEN -Fpcn` and `lsof -nP -iUDP -Fpcn`. Parse the field-mode output (`p` = pid, `c` = command, `n` = name). Bind ip:port comes from the `n` field.
- Windows: `netstat -ano -p TCP` + `netstat -ano -p UDP` + `tasklist /FO CSV /NH` for pid→process resolution. **Deferred to a follow-up.** Windows stub returns an empty array and logs once.

**Filtering rules** applied to raw scan output:

- Drop rows where the port equals any port in `config.listeners` (parse via `@url.Url::parse`) — that is msgtier itself.
- Drop the `port_forward_registry_state.tcp_forward_servers` and `udp_forward_runtimes` bindings — those are mappings this node has already created (peer would see itself echoed).
- Drop process name `"msgtier"` as a paranoia belt-and-suspenders check.

## Local Port Allocation

When the WebUI creates a mapping with no explicit `local_port`, the store picks one:

1. Candidate = `remote_port + 40000` (e.g. `5432 → 45432`). If `remote_port + 40000 > 65535`, wrap around to `remote_port + 20000`.
2. Bind-probe: try `TcpServer::new("127.0.0.1:CAND")` (or `UdpServer` for UDP). If it succeeds, close and use `CAND`.
3. On conflict, walk `CAND+1 … 65534`, skipping any port already used by another `PortMapping` or by msgtier itself, until an available one is found.
4. If none available in a bounded search (say 200 attempts), return HTTP 409 with the last attempted number, letting the UI ask the user for one.

## HTTP API

All endpoints return JSON. `Content-Type: application/json` on request bodies. Errors:

```
{ "error": "<code>", "message": "<human>" }
```

with an appropriate 4xx/5xx status.

| Method | Path | Body | Response | Purpose |
|---|---|---|---|---|
| GET | `/api/port_scan/local` | — | `{ "ports": [LocalPortEntry] }` | Show what this node scanned. |
| GET | `/api/port_scan/peers` | — | `{ "peers": { peer_id: { "last_updated": ms, "ports": [...] } } }` | Show remote view. |
| POST | `/api/port_scan/refresh` | — | `{ "scanned": N, "broadcast": true }` | Force scan + broadcast. |
| GET | `/api/port_mappings` | — | `{ "mappings": [PortMapping] }` | List. |
| POST | `/api/port_mappings` | `{ peer_id, remote_protocol, remote_host?, remote_port, local_host?, local_port?, note? }` | `PortMapping` | Create; on port conflict 409. |
| DELETE | `/api/port_mappings/:id` | — | `{ "removed": true }` | Delete. |
| PATCH | `/api/port_mappings/:id` | `{ "enabled": bool }` or `{ "note": "..." }` | `PortMapping` | Toggle / edit note. |

Notes:

- The `POST /api/port_mappings` handler validates that `peer_id` exists in the known peers registry (`get_global_peer_manager()`), even if the peer is currently offline.
- The scan-refresh endpoint waits for the scan+diff before returning (async).
- CORS: not addressed here; use whatever the existing HTTP service does.

## Runtime Integration with Existing `port_forward_*`

The message layer is unchanged. What changes is where forwarding rules come from:

Before: `config.forwards[peer:rule_id] = "tcp://127.0.0.1:port"` → parsed to `PortForwardForwardRule` → listener started.

After: `PortMapping` in the store → adapted (in `port_mapping_store.mbt`) to a `PortForwardForwardRule` — the shape already matches — → passed to `start_port_forward_tcp_listener` / `start_port_forward_udp_listener` at boot and on mutation. The listener code and downstream `port_forward_open` / `port_forward_data` / `port_forward_close` protocol is not touched.

On the **expose side** (the machine hosting the actual service), the existing handler `handle_port_forward_open_message` currently looks up an `exposes` entry to know where to dial. With `exposes` gone, the handler MUST accept the connect request based purely on the *rule_id* being the actual protocol/host/port to dial. The dial address travels with the open message; the receiver validates it against its own recent scan (port must appear in `local_ports` set) and rejects otherwise. This preserves the "you can only pull ports the peer actually broadcasts" invariant.

Concretely, the new `port_forward_open` body from the puller includes the exact target:

```
{
  "connection_id": "...",
  "protocol": "tcp",
  "target_host": "127.0.0.1",
  "target_port": 5432
}
```

and drops the old `rule_id` field (or leaves it as a stable-string derived from the tuple, for audit). The exposer checks `target_host + target_port` is in its currently-broadcast set and, if so, dials it.

## Cleanup

**Removed:**

- `Config.forwards`, `Config.exposes` fields and all their JSON/hot-reload plumbing.
- `PortForwardExposeRule` struct and `get_port_forward_expose_rules()`.
- `parse_port_forward_expose_spec`, `parse_port_forward_forward_spec`.
- All references in `config.mbt`, `crypto_wbtest.mbt`, `config_wbtest.mbt`, `http_proxy_internal_wbtest.mbt`, `message_dispatcher_wbtest.mbt`, `message_service_wbtest.mbt`, `port_forward_wbtest.mbt`, `server_wbtest.mbt`.
- `tests/port_forward_node_a.jsonc` and `tests/port_forward_node_b.jsonc` (rely on config → obsolete).
- Frontend: `forwardsText` / `exposesText` fields in `ConfigPanel.vue`; the old read-only `PortForwardsPanel.vue` gets replaced (this spec keeps the file name for the new panel).

**Kept unchanged:**

- `port_forward_open/data/close/error/open_ack` messages and their handlers (aside from the target-address change above).
- `PortForwardTcpEndpoint`, `PortForwardUdpForwardRuntime`, `PortForwardUdpExposeSession`.
- `start_port_forward_tcp_listener`, `start_port_forward_udp_listener`, `run_port_forward_tcp_writer`, `accept_port_forward_tcp_connection`.
- `port_forward_audit` machinery.

## Testing

- Unit: `port_scanner_test.mbt` — feed canned lsof output through `parse_lsof_output`, assert extracted `LocalPortEntry` list; test `diff_local_ports` against curated pairs.
- Unit: `port_mapping_store_test.mbt` — round-trip JSON, atomic write behavior via tmp file, corrupted-file fallback.
- Unit: extend `port_forward_wbtest.mbt` — remove all references to `Config.forwards`/`Config.exposes`; add tests for `port_scan_snapshot` / `port_scan_delta` body parsing.
- Integration (deferred): a scripted two-node run that scans, broadcasts, creates a mapping via the API, and validates end-to-end forwarding — this is a follow-up plan since it needs the Python harness in `tests/` to be updated.

## Migration

There is no in-place migration path for existing users' `forwards` / `exposes` config values — those fields are removed and no auto-conversion runs. Anyone upgrading needs to re-create the mappings via the WebUI once. Since the project is pre-1.0 and unshipped, this is acceptable; the README/get-started doc will get an entry describing the change.

## Risk & Mitigation

| Risk | Mitigation |
|---|---|
| `lsof` not installed (bare Linux container) | Detect on first run; fall back to `/proc/net/tcp` reader on Linux; log and return empty list on other platforms. |
| Broadcast storms if a machine has hundreds of listeners | Deltas keep steady-state traffic near zero; initial snapshot per peer is a one-time cost. |
| A peer's malicious broadcast asks another peer to open a mapping to an unrelated internal port | The exposer validates the requested target against its own broadcast set; unknown targets are rejected. |
| Mapping file corruption | Atomic write + safe load-with-fallback keeps the runtime alive with an empty store. |
| Users lose config-driven rules on upgrade | Called out in migration section; must be documented in changelog. |

## Open Questions

None currently.
