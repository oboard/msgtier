# MsgTier - Decentralized P2P Messaging Network

MsgTier is a lightweight, decentralized P2P messaging network written in **MoonBit**. It enables nodes to discover each other, establish secure connections, and communicate with automatic message relay capabilities - all without requiring a central server.

## Features

✨ **Auto-Discovery** - Nodes automatically discover peers through the network
🔐 **End-to-End Encryption** - X25519 ECDH key exchange with symmetric encryption
🔄 **Message Relay** - Messages are automatically relayed through intermediate peers (Intra-network)
🌍 **Foreign Network Relay** - Cross-network relay via public nodes when direct routes fail
💓 **Health Checks** - Continuous heartbeat monitoring with automatic failure detection
🔌 **Script Execution** - Execute custom scripts on message receipt
🌐 **Multi-Transport** - Support for UDP, TCP, and WebSocket protocols
💻 **Cross-Platform** - Runs on Windows, macOS, and Linux
📊 **HTTP API** - REST endpoints for peer status, config, and message sending

## Quick Start

### 1. Configuration

Create a `node.json` config file:

```json
{
  "id": "1",
  "secret": "your-secret-key",
  "listeners": [
    "udp://0.0.0.0:6666",
    "tcp://0.0.0.0:6667",
    "ws://0.0.0.0:6668"
  ],
  "peers": [
    "udp://127.0.0.1:6669",
    "ws://127.0.0.1:6670"
  ],
  "relay_network_whitelist": "*",
  "relay_all_peer_rpc": true,
  "foreign_relay_bps_limit": 1048576,
  "web_api": "127.0.0.1:9000",
  "scripts": {
    "chrome": "open /Applications/Google\\ Chrome.app",
    "notepad": "notepad.exe"
  }
}
```

### 2. Start Nodes

```bash
./msgtier node1.json
./msgtier node2.json
./msgtier node3.json
```

### 3. Send Messages

```bash
curl --location 'localhost:9000/send' \
  --header 'target: 1' \
  --data 'chrome'
```

## Architecture

### Message Types

- **hello** - Initial greeting with version info and public key
- **welcome** - Response with known peer list and public key for discovery
- **ping** - Health check heartbeat
- **pong** - Heartbeat response
- **data** - User message (always encrypted binary payload, triggers script execution)
- **relay** - Forward message through intermediate peer
- **punch** - NAT traversal request

### End-to-End Encryption

MsgTier implements X25519 Elliptic Curve Diffie-Hellman (ECDH) key exchange with symmetric encryption. **All data messages are encrypted**, including those sent to self (loopback).

1. **Key Generation** - Each node generates an X25519 key pair on startup
2. **Key Exchange** - Public keys are exchanged during the hello/welcome handshake
3. **Shared Secret** - Peers compute shared secrets via ECDH (including a self-shared secret for loopback)
4. **Encryption** - All data payloads are symmetrically encrypted using the shared secret

**Encryption Flow:**
```
Sender                          Receiver
   │                               │
   │  1. Exchange public keys      │
   │     (hello/welcome handshake) │
   ├──────────────────────────────►│
   │◄──────────────────────────────┤
   │                               │
   │  2. Both compute shared       │
   │     secret via X25519 ECDH    │
   │                               │
   │  3. Encrypt with shared secret│
   │     (Force Binary MsgPack)    │
   ├──────────────────────────────►│
   │                               │
   │  4. Decrypt with shared secret│
   │                               │
```

Messages are automatically encrypted. If a peer's shared secret is not available, transmission falls back to unencrypted with a warning (but for `data` messages, we strive for encryption).

### Peer Discovery

The network uses a gossip-based peer discovery mechanism:

1. Node reads configuration with initial peer list
2. Node sends `hello` messages to configured peers
3. Peers respond with `welcome` containing their known peers
4. Node automatically discovers and connects to new peers
5. Each new peer is greeted with a `hello` message
6. Network topology expands organically

**Example - Multi-hop Discovery:**
```
node1.json → peers: [node2]
node2.json → peers: [node1, node3]
node3.json → peers: [node2]

Result:
- node1 connects to node2 (configured)
- node2 sends welcome with node3's address
- node1 automatically discovers and connects to node3
- All nodes can communicate with each other
```

### Health Monitoring

The system implements continuous connection health monitoring:

- **Heartbeat Interval**: 10 seconds - Periodic ping sent to all peers
- **Timeout Threshold**: 30 seconds - No pong response marks connection inactive
- **Automatic Reconnection**: Failed connections retry with exponential backoff
- **Connection State Tracking**: Each connection is marked as Active/Disconnected
- **Real-time Status**: Query via HTTP `/status` endpoint to monitor health

Connections that don't receive pong responses within 30 seconds are automatically marked as disconnected, and the system attempts to reconnect periodically.

### Message Flow

Messages flow through the system in the following sequence:

```
┌─────────────────┐
│  HTTP Client    │  User sends POST /send
└────────┬────────┘
         │ {target: "peer_id", body: "message"}
         ▼
┌──────────────────────────┐
│  HTTP Handler            │  1. Check if Loopback (target == self) -> Direct Queue
│  (add_pending_message)   │  2. Else -> Encrypt & Queue for Remote
└────────┬─────────────────┘
         │
         ▼
┌──────────────────────────┐
│  Pending Message         │  Background task processes queue every 100ms
│  Processor (100ms loop)  │  Find best active connection to target
└────────┬─────────────────┘
         │
         ▼
┌──────────────────────────┐
│  Transport Layer         │  Send message via UDP/TCP/WS to remote address
│  (via active connection) │  OR Handle Loopback internally
└────────┬─────────────────┘
         │
         ▼
┌──────────────────────────┐
│  Target Node             │  Receive and process message
│  (Listener)              │
└────────┬─────────────────┘
         │ Decrypt & Parse
         ▼
   ┌─────────────────────────────────────┐
   │  Is kind == "data"?                 │
   │  Does body match a script name?     │
   └──────────┬────────────────────┬─────┘
              │                    │
        Yes   │                    │  No
              ▼                    ▼
      ┌─────────────┐       ┌──────────────┐
      │  Execute    │       │  Message     │
      │  Script     │       │  Logged Only │
      └─────┬───────┘       └──────────────┘
            │
            ▼
      ┌─────────────┐
      │ Send        │
      │ Response    │
      └─────────────┘
```

**Key Features:**
- **Asynchronous Processing**: HTTP handler waits for response (with timeout) but processing is async.
- **Unified Encryption**: All data messages are encrypted, even to self.
- **Best Connection Selection**: Automatically picks active connection with best quality.
- **Script Matching**: Message body matched against configured script names (case-sensitive).
- **Platform-Specific Execution**: Scripts run via platform-specific shells (Windows: cmd.exe, Unix: sh).

## HTTP API

### GET /config
Returns the current node configuration

```bash
curl http://127.0.0.1:9000/config
```

### GET /status
Returns connection status and peer information

```bash
curl http://127.0.0.1:9000/status
```

Response includes:
- All active/inactive connections
- Peer IDs and versions
- Local and remote addresses
- Connection state

### POST /send
Send a message to a target peer

```bash
curl --location 'http://127.0.0.1:9000/send' \
  --header 'target: peer_id' \
  --data 'message_body'
```

## Cross-Platform Script Execution

Scripts are executed using platform-specific shells:

- **Linux/macOS**: `sh -c "command"`
- **Windows**: `cmd.exe /c "command"`

Example scripts in config:

```json
"scripts": {
  "browser": "open https://example.com",        // macOS
  "browser": "start https://example.com",       // Windows
  "alert": "echo 'Hello'",                       // Any platform
  "backup": "./backup.sh"                        // Any platform
}
```

## How It Works

### 1. Initialization Phase

On startup, the node:
- Loads configuration from JSON file (node ID, listeners, peers, scripts)
- **Generates X25519 key pair for end-to-end encryption**
- Starts HTTP API server on configured address
- Creates UDP listeners on all configured addresses
- Spawns three background tasks per listener: heartbeat, reconnection, pending message processing

### 2. Connection Establishment

For each listener, the system:
- Reads initial peer list from configuration
- Sends `hello` messages to all configured peer addresses **with public key**
- Builds a peer information structure as responses arrive
- **Computes shared secrets with peers for encryption**
- Creates and tracks connections (local_addr ↔ remote_addr pairs)
- Handles version exchange for compatibility tracking

### 3. Peer Discovery via Gossip

When a `hello` message is received:
1. A `welcome` message is sent back containing all known peers **and the node's public key**
2. The sender extracts unknown peers from the welcome message
3. **The sender computes a shared secret with the peer for future encrypted communication**
4. New peers are automatically discovered and greeted with `hello`
5. This creates an organic network topology without manual configuration

### 4. Health Management Loop

The heartbeat background task:
- Every 10 seconds: Sends `ping` to all known peer connections
- Tracks `pong` responses and updates `last_seen` timestamps
- After 30 seconds without a pong: Marks connection as inactive
- Continues monitoring for reconnection opportunity

### 5. Message Sending

When HTTP POST /send is received:
- **Encryption**: Payload is encrypted using the shared secret for the target (or self)
- **Queuing**: Encrypted message is added to `pending_messages`
- **Processing**: Background task (100ms interval) retrieves the queue
- **Routing**: Finds best active connection to target peer (or uses Loopback)
- **Transmission**: Sends message via appropriate transport (UDP/TCP/WS)
- **Cleanup**: Clears processed messages from queue

### 6. Message Reception and Script Execution

When a message arrives (via any transport):
- Message is decoded from MessagePack format
- Connection state is updated (marked Active)
- **Decryption**: Message is decrypted using the shared secret
- If message type is `data`: extract script name from body
- Lookup script name in configuration scripts map
- If found: spawn async task to execute script with platform-specific shell
- Execute asynchronously to avoid blocking the transport handler

### Message Types Reference

| Type | Direction | Purpose |
|------|-----------|---------|
| `hello` | Bidirectional | Initial greeting with version info |
| `welcome` | Response | Contains peer list for discovery |
| `ping` | To peer | Health check request |
| `pong` | Response | Health check response |
| `data` | To peer | User message (triggers script) |
| `send` | Internal | Message send request |
| `relay` | To relay peer | Forward message through intermediate |
| `punch_request` | For NAT | Initiate NAT traversal |
| `punch` | For NAT | NAT traversal message |
| `punch_ack` | For NAT | NAT traversal acknowledgment |

### Connection State Machine

```
         ┌──────────┐
         │   Init   │
         └────┬─────┘
              │ hello received
              ▼
         ┌──────────┐
    ┌────│ Active   │◄────┐
    │    └──────────┘     │
    │         │           │
    │  30s    │ pong      │ reconnect
    │  no     │ received  │ succeeds
    │  pong   │           │
    │         ▼           │
    │    ┌──────────┐     │
    └───►│Disconnect├─────┘
         └──────────┘
```

## Development

```bash
# Format code
moon fmt

# Check code
moon check

# Run tests
moon test

# Update package interfaces
moon info
```

## Example: Multi-Node Setup

```bash
# Terminal 1: Node 1 (port 6666)
./msgtier node1.json

# Terminal 2: Node 2 (port 6668)
./msgtier node2.json

# Terminal 3: Node 3 (port 6670)
./msgtier node3.json

# Terminal 4: Send message from Node 3 to Node 1 through Node 2
curl -X POST 'http://localhost:9002/send' \
  -H 'target: 1' \
  -d 'chrome'
```

Node 3 will:
1. Connect to Node 2 (from config)
2. Receive welcome from Node 2 with Node 1's address
3. Auto-discover and connect to Node 1
4. Route message through best available path
5. Node 1 executes the "chrome" script

## License

Apache-2.0
