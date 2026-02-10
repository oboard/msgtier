# Architecture

## Message Types

- **hello** - Initial greeting with version info and public key
- **welcome** - Response with known peer list and public key for discovery
- **ping** - Health check heartbeat
- **pong** - Heartbeat response
- **data** - User message (always encrypted binary payload, triggers script execution)
- **relay** - Forward message through intermediate peer
- **punch** - NAT traversal request

## End-to-End Encryption

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

## Peer Discovery

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

## Foreign Network Relay

When a direct P2P connection or intra-network route cannot be established, MsgTier supports **Foreign Network Relay**. This allows messages to be forwarded across different networks via public nodes.

1.  **Packet Wrapping**: The original message is wrapped in a `ForeignNetworkPacket`, preserving the destination network and peer ID.
2.  **Public Node Fallback**: If the `PeerManager` finds no route in its routing table, it searches for a connected "public node" (non-private IP).
3.  **Forwarding**: The wrapped packet is sent to the public node, which acts as a gateway/relay.
4.  **Unwrapping**: The receiving node unwraps the packet and attempts to deliver it to the final destination (either directly or by relaying further).
5.  **Rate Limiting**: To prevent abuse, foreign relays are subject to bandwidth limits configured via `foreign_relay_bps_limit`.

## Health Monitoring

The system implements continuous connection health monitoring:

- **Heartbeat Interval**: 10 seconds - Periodic ping sent to all peers
- **Timeout Threshold**: 30 seconds - No pong response marks connection inactive
- **Automatic Reconnection**: Failed connections retry with exponential backoff
- **Connection State Tracking**: Each connection is marked as Active/Disconnected
- **Real-time Status**: Query via HTTP `/status` endpoint to monitor health

Connections that don't receive pong responses within 30 seconds are automatically marked as disconnected, and the system attempts to reconnect periodically.

## Message Flow

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
│  Processor (100ms loop)  │  Route via direct conn, intra-network relay,
│                          │  or public node (foreign relay)
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

## How It Works

### 1. Initialization Phase

On startup, the node:
- Loads configuration from JSON file (node ID, listeners, peers, scripts)
- **Generates X25519 key pair for end-to-end encryption**
- Starts HTTP API server on configured address
- Creates listeners on all configured addresses (UDP, TCP, WebSocket)
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
- **Routing**: Finds best active connection, internal route, or public relay fallback
- **Transmission**: Sends message via appropriate transport (UDP/TCP/WS)
- **Cleanup**: Clears processed messages from queue

### 6. Message Reception and Script Execution

When a message arrives (via any transport):
- Message is decoded from MessagePack format
- Connection state is updated (marked Active)
- **If message is encrypted: decrypt using shared secret derived from X25519 ECDH**
- If message type is `data`: extract script name from body
- Lookup script name in configuration scripts map
- If found: spawn async task to execute script with platform-specific shell
- Execute asynchronously to avoid blocking the transport handler

## Message Types Reference

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

## Connection State Machine

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
