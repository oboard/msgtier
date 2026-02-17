# Getting Started with MsgTier

MsgTier is a decentralized P2P messaging network that enables nodes to discover each other and communicate securely without a central server.

## Installation

Build MsgTier from source:

```bash
git clone <repository>
cd msgtier
moon build
```

## Configuration

Create a `node.json` configuration file for each node:

```json
{
  "id": "1",
  "secret": "shared-secret-key",
  "listeners": [
    "udp://0.0.0.0:6666",
    "tcp://0.0.0.0:6667",
    "ws://0.0.0.0:6668"
  ],
  "peers": [
    "udp://127.0.0.1:6669",
    "ws://127.0.0.1:6670"
  ],
  "web_api": "127.0.0.1:9000",
  "scripts": {
    "open_browser": "open /Applications/Google\\ Chrome.app",
    "notify": "echo 'Message received'"
  }
}
```

### Configuration Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | String | Unique identifier for this node |
| `secret` | String | Shared secret key (reserved for future use) |
| `listeners` | Array | Addresses to listen on. Supported protocols: `udp://`, `tcp://`, `ws://`. Use 0.0.0.0 to bind all interfaces |
| `peers` | Array | Initial peer addresses to connect to. Supported protocols: `udp://`, `tcp://`, `ws://` |
| `relay_network_whitelist` | Array[String] | List of allowed target networks for relay (default: ["*"]) |
| `relay_all_peer_rpc` | Boolean | Whether to relay RPC messages even if not in whitelist (default: true) |
| `foreign_relay_bps_limit` | Number | Bandwidth limit (bytes/sec) for foreign network relay (default: 0 = unlimited) |
| `web_api` | String | HTTP server address (optional) |
| `scripts` | Object | Named scripts that can be triggered via messages |

## Running Nodes

### Single Node

```bash
./msgtier node.json
```

Output:
```
X25519 key pair generated successfully
{
  "id": "1",
  "secret": "secret-key",
  "listeners": ["0.0.0.0:6666"],
  "peers": [],
  "web_api": "127.0.0.1:9000"
}
Listening on 0.0.0.0:6666
HTTP API listening on http://127.0.0.1:9000
```

### Multi-Node Network

**Terminal 1 - Node 1:**
```bash
./msgtier node1.json
```

**Terminal 2 - Node 2:**
```bash
./msgtier node2.json
```

**Terminal 3 - Node 3:**
```bash
./msgtier node3.json
```

## End-to-End Encryption

MsgTier automatically handles encryption using X25519 ECDH:

1. **On startup**: Each node generates an X25519 key pair (fast elliptic curve)
2. **During handshake**: Public keys are exchanged in hello/welcome messages
3. **Shared secret**: Both peers compute the same shared secret via ECDH
4. **When sending**: Messages are symmetrically encrypted with the shared secret
5. **When receiving**: Messages are decrypted with the same shared secret

You'll see log messages like:
```
X25519 key pair generated successfully
Computed shared secret with peer 2
```

If a peer's shared secret is not available, messages are sent unencrypted with a warning:
```
Warning: Sending unencrypted message to peer_id (no shared secret available)
```

## Sending Messages

### HTTP API

Send a message to a peer using the REST API:

```bash
curl -X POST 'http://127.0.0.1:9000/api/send' \
  -H 'target: 1' \
  -d 'script_name'
```

- `target` header: ID of the destination peer
- Body: Name of the script to trigger

### Script Execution

When a message is received, if the message body matches a script name in the config, the script is executed:

```json
"scripts": {
  "chrome": "open /Applications/Google\\ Chrome.app"
}
```

Send via HTTP:
```bash
curl -X POST 'http://localhost:9000/api/send' \
  -H 'target: 1' \
  -d 'chrome'
```

Node will execute: `open /Applications/Google\ Chrome.app`

## Checking Connection Status

View connection status and peer information:
```bash
curl http://127.0.0.1:9000/api/status
```

## Troubleshooting

### Connection Issues

**Problem:** Nodes aren't discovering each other

**Solution:**
- Ensure firewall allows UDP on configured ports
- Verify peer addresses are correct and reachable
- Check logs for "Discovered new peer" messages

### Script Not Executing

**Problem:** Message received but script didn't run

**Solution:**
- Verify script name exactly matches config
- Check script syntax (platform-specific shells)
- View logs for script execution status

### Encryption Issues

**Problem:** "No public key available" warnings

**Solution:**
- Wait for peers to complete handshake (hello/welcome exchange)
- Check that peers are running compatible versions
- Verify network connectivity

### High Latency

**Problem:** Messages taking long time to deliver

**Solution:**
- Check connection status: `curl http://localhost:9000/api/status`
- Verify heartbeat/pong responses working
- Consider network topology - use nodes as relays

## Next Steps

- Check [API Examples](/api-examples) for detailed endpoint documentation
- Explore cross-platform script capabilities
- Set up multi-node clusters for testing message relay
