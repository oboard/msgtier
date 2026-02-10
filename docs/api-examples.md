---
outline: deep
---

# API Examples

MsgTier provides a REST HTTP API for managing nodes and sending messages.

## Base URL

```
http://localhost:9000
```

Replace `9000` with the port configured in your node's `web_api` field.

## Endpoints

### GET /config

Returns the current node's configuration.

**Request:**
```bash
curl http://localhost:9000/config
```

**Response:**
```json
{
  "id": "1",
  "secret": "my-secret",
  "listeners": [
    "udp://0.0.0.0:6666",
    "tcp://0.0.0.0:6667"
  ],
  "peers": [
    "udp://127.0.0.1:6668",
    "ws://127.0.0.1:6669"
  ],
  "relay_network_whitelist": "*",
  "relay_all_peer_rpc": true,
  "foreign_relay_bps_limit": 1048576,
  "web_api": "127.0.0.1:9000",
  "scripts": {
    "chrome": "open /Applications/Google\\ Chrome.app",
    "notify": "echo 'Hello'"
  }
}
```

---

### GET /status

Returns real-time connection status and peer information.

**Request:**
```bash
curl http://localhost:9000/status
```

**Response:**
```json
{
  "status": "ok",
  "connections": [
    {
      "id": "conn_1",
      "local_addr": "0.0.0.0:6666",
      "remote_addr": "127.0.0.1:6668",
      "peer_id": "2",
      "state": "Active",
      "last_seen": 1625000000,
      "quality": 100,
      "relay": 0,
      "metadata": {},
      "latency_ms": 15,
      "latency_history": [10, 15, 20],
      "packets_sent": 150,
      "packets_lost": 0,
      "bytes_sent": 10240,
      "bytes_received": 8192,
      "last_ping_time": 1625000000,
      "bandwidth_mbps": 100.0,
      "packet_loss_rate": 0
    }
  ],
  "peers_count": 2,
  "active_connections": 2,
  "total_connections": 2,
  "node_name": "1",
  "listeners": [
    "0.0.0.0:6666",
    "0.0.0.0:6667"
  ]
}
```

**Response Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `status` | String | Overall status ("ok") |
| `connections` | Array | List of all connections |
| `peers_count` | Number | Total unique peers |
| `active_connections` | Number | Number of active connections |
| `total_connections` | Number | Total connections (active + inactive) |
| `node_name` | String | This node's ID |
| `listeners` | Array | All listening addresses |

**Connection Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `id` | String | Unique connection identifier |
| `peer_id` | String | ID of the connected peer |
| `state` | String | Connection state (Active, Disconnected, etc.) |
| `local_addr` | String | Local address used for this connection |
| `remote_addr` | String | Remote peer's address |
| `latency_ms` | Number | Current latency in milliseconds |
| `packet_loss_rate` | Number | Packet loss rate (0-100) |
| `bandwidth_mbps` | Number | Estimated bandwidth in Mbps |
| `last_seen` | Number | Timestamp of last activity |
| `quality` | Number | Connection quality score |

---

### POST /send

Send a message to a target peer. Messages are automatically encrypted using X25519 ECDH shared secrets when available.

**Request:**
```bash
curl -X POST 'http://localhost:9000/send' \
  -H 'target: 2' \
  -d 'chrome'
```

**Headers:**

| Header | Required | Description |
|--------|----------|-------------|
| `target` | Yes | Peer ID of the destination |
| `Content-Type` | No | Request content type (default: application/octet-stream) |

**Body:**

The request body is the message data (typically a script name).

**Success Response (200 OK):**
```json
{
  "status": "ok",
  "output": "Script output here..."
}
```

**Timeout Response (504):**
```json
{
  "error": "Request timed out",
  "target": "2"
}
```

**Peer Not Found (404):**
```json
{
  "error": "Target peer not found",
  "target": "2"
}
```

**Missing Target Header (400):**
```json
{
  "error": "Missing target header"
}
```

---

## Examples

### Example 1: Check Node Status

```bash
curl http://localhost:9000/status | jq '.connections | length'
```

Output: Number of total connections

### Example 2: Send Script Trigger

Trigger the "chrome" script on peer "1":

```bash
curl -X POST 'http://localhost:9000/send' \
  -H 'target: 1' \
  -d 'chrome'
```

### Example 3: Send Custom Message

Send a custom message to a peer:

```bash
curl -X POST 'http://localhost:9000/send' \
  -H 'target: 1' \
  -d 'hello world'
```

Note: If "hello world" is not a configured script name, the message is received but no script executes.

### Example 4: Monitor Connections in Real-Time

```bash
# Watch connection status every second
watch -n 1 "curl -s http://localhost:9000/status | jq '.active_connections'"
```

### Example 5: List All Connected Peers

```bash
curl -s http://localhost:9000/status | jq '.connections[] | .peer_id' | sort -u
```

### Example 6: Check for Inactive Connections

```bash
curl -s http://localhost:9000/status | jq '.connections[] | select(.active == false)'
```

### Example 7: Automated Health Check

```bash
#!/bin/bash
while true; do
  status=$(curl -s http://localhost:9000/status)
  active=$(echo "$status" | jq '.active_connections')
  total=$(echo "$status" | jq '.total_connections')
  echo "$(date): Active: $active / Total: $total"
  sleep 5
done
```

---

## Error Handling

### Common Errors

**400 Bad Request**
```json
{
  "error": "Missing target header"
}
```
Solution: Add `target` header with peer ID

**404 Not Found**
```json
{
  "error": "Target peer not found",
  "target": "unknown-peer"
}
```
Solution: Verify peer exists - check `/status` endpoint

**503 Service Unavailable**
```json
{
  "error": "No active connection to target"
}
```
Solution: Wait for peer to connect and become active

---

## Message Routing

When you send a message:

1. **Encryption**: If a shared secret with the target peer is available, the message is encrypted using X25519 ECDH
2. **Direct Route**: If target peer has active connections, message is sent directly
3. **Relay Route**: If target has no active connections but is reachable through another peer, message is relayed
4. **Queued**: Message is queued if target isn't currently reachable
5. **Failed**: Returns error if target peer doesn't exist in network

**Note:** Messages to peers without an established shared secret are sent unencrypted with a warning logged.

---

## Rate Limiting

No rate limiting is currently implemented. Use reasonable request intervals to avoid overwhelming the network.

---

## Best Practices

1. **Always check /status** before sending critical messages
2. **Handle 404 errors gracefully** - peer may not have discovered yet
3. **Use meaningful script names** in config for clarity
4. **Monitor active_connections** to detect network issues
5. **Implement retry logic** for failed sends with exponential backoff

---

## Troubleshooting API Issues

**Issue: Always getting 404 for valid peers**
- Check node discovery logs
- Verify peer addresses in config
- Wait 10+ seconds for peer discovery to complete

**Issue: Connections showing as inactive**
- Check firewall rules for UDP
- Verify network connectivity
- Review heartbeat logs for pong responses

**Issue: Message not triggering script**
- Verify script name matches exactly (case-sensitive)
- Check script syntax for your platform
- Review server logs for execution errors
