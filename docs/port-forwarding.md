# Port Forwarding

MsgTier supports static peer-to-peer port forwarding for bastion-style access. It is designed for cases like:

- exposing SSH from a remote node
- forwarding a database port through another node
- exposing a private UDP service such as DNS

This is not a dynamic SOCKS proxy. Both sides must declare the same rule key in config.

## How It Works

There are two roles:

- `forwards`: the local listening side
- `exposes`: the remote target side

MsgTier matches a tunnel by:

- peer id
- rule key

If node A wants to reach node B's SSH service:

- node A adds a `forwards` entry
- node B adds `exposes.ssh`

Once both nodes are online and connected, node A gets a local TCP port. Connecting to that local port forwards traffic to node B's configured target.

## Config Format

`forwards` uses this format:

```json
{
  "forwards": {
    "node-b:ssh": "tcp://127.0.0.1:10022"
  }
}
```

Meaning:

- key format: `peer_id:rule_id`
- key peer id: `node-b`
- key rule id: `ssh`
- value protocol: `tcp`
- value local listen address: `127.0.0.1:10022`

`exposes` uses this format:

```json
{
  "exposes": {
    "ssh": "tcp://127.0.0.1:22"
  }
}
```

Meaning:

- rule key: `ssh`
- protocol: `tcp`
- remote target address: `127.0.0.1:22`

## SSH Example

This is the most common setup.

Assume:

- `node-a` is your laptop
- `node-b` is a remote machine running SSH on port `22`
- you want to SSH to `node-b` by connecting to `127.0.0.1:10022` on `node-a`

### Node A

`node-a.jsonc`:

```json
{
  "id": "node-a",
  "secret": "shared-secret",
  "listeners": [
    "tcp://0.0.0.0:16101"
  ],
  "peers": [
    "tcp://node-b.example.com:16102"
  ],
  "web_api": "127.0.0.1:19100",
  "forwards": {
    "node-b:ssh": "tcp://127.0.0.1:10022"
  }
}
```

### Node B

`node-b.jsonc`:

```json
{
  "id": "node-b",
  "secret": "shared-secret",
  "listeners": [
    "tcp://0.0.0.0:16102"
  ],
  "peers": [],
  "web_api": "127.0.0.1:19101",
  "exposes": {
    "ssh": "tcp://127.0.0.1:22"
  }
}
```

### Use It

Start both nodes, wait until they are connected, then on `node-a` run:

```bash
ssh -p 10022 user@127.0.0.1
```

That connection path is:

```text
ssh client on node-a
  -> 127.0.0.1:10022
  -> MsgTier forward rule ssh
  -> node-b
  -> 127.0.0.1:22 on node-b
```

## Jump To Another Host Behind The Remote Node

The expose side can also point at another address reachable from that node.

For example, if `node-b` can reach `10.0.0.15:22` on its private LAN:

```json
{
  "exposes": {
    "ssh": "tcp://10.0.0.15:22"
  }
}
```

Then `ssh -p 10022 user@127.0.0.1` on `node-a` will reach that private host through `node-b`.

This is the intended bastion use case.

## UDP Example

UDP uses the same rule structure:

```json
{
  "forwards": {
    "node-b:dns": "udp://127.0.0.1:1053"
  },
  "exposes": {
    "dns": "udp://127.0.0.1:53"
  }
}
```

Then on the forward side you can query:

```bash
dig @127.0.0.1 -p 1053 example.com
```

## Web UI

Open the network page in the Web UI. The port forwarding panel shows:

- rule key
- direction: `forward` or `expose`
- protocol
- peer id for forward rules
- local listen address for forward rules
- current state

Common states:

- `listening`: local forward port is active
- `configured`: rule exists but is not yet listening or matched
- `peer_unavailable`: the target peer is not currently reachable
- `disabled`: the rule is not active

## Troubleshooting

If the tunnel does not work, check these points first:

1. The two nodes must use the same rule key.
2. The `forwards` rule must point to the correct peer id.
3. `secret` must match on both nodes.
4. The exposed target must actually be reachable from the expose node.
5. The local listen port must not already be occupied.

Useful checks:

```bash
curl http://127.0.0.1:19100/api/status
curl http://127.0.0.1:19101/api/status
```

Look for:

- the peer appearing in `peers`
- direct connections being present
- `metadata.port_forwards`

For the SSH example, also verify the target directly on the expose node:

```bash
ssh 127.0.0.1
```

or just check that port `22` is listening there.

## Notes

- The forward side is always a local listener.
- The expose side chooses the final target address.
- MsgTier does not let the client choose arbitrary target addresses at runtime.
- This keeps the feature predictable and suitable for controlled bastion access.
