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
    "udp://0.0.0.0:6667"
  ],
  "peers": [
    "udp://127.0.0.1:6668",
    "udp://127.0.0.1:6669"
  ],
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
      "peer_id": "2",
      "version": "0.1.0",
      "active": true,
      "local_addr": "0.0.0.0:6666",
      "remote_addr": "127.0.0.1:6668"
    },
    {
      "peer_id": "2",
      "version": "0.1.0",
      "active": true,
      "local_addr": "0.0.0.0:6667",
      "remote_addr": "127.0.0.1:6668"
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
| `peer_id` | String | ID of the connected peer |
| `version` | String | Peer's software version |
| `active` | Boolean | Whether connection is currently active |
| `local_addr` | String | Local address used for this connection |
| `remote_addr` | String | Remote peer's address |

---

### POST /send

Send a message to a target peer.

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
  "status": "queued",
  "target": "2",
  "data": "chrome"
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

1. **Direct Route**: If target peer has active connections, message is sent directly
2. **Relay Route**: If target has no active connections but is reachable through another peer, message is relayed
3. **Queued**: Message is queued if target isn't currently reachable
4. **Failed**: Returns error if target peer doesn't exist in network

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
