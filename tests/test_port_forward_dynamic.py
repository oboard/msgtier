"""End-to-end test for the dynamic port-forward flow.

The old static-config port-forward path (`forwards`/`exposes` in the node
config) has been removed. Real usage now goes through the runtime API path,
which this test exercises:

  1. Two nodes come up with just listeners + peers + web_api.
  2. Node B's port scanner discovers a local HTTP server on port 19480.
  3. Node A pulls B's port list via GET /api/port_scan/peers.
  4. Node A creates a port mapping via POST /api/port_mappings (auto-alloc local port).
  5. Traffic on the allocated local port tunnels through to B and reaches the HTTP server.

Because the target server is a plain TCP LISTEN, we sweep several
`remote_protocol` values that represent common TCP-based application labels
(and one arbitrary/custom label). All of them must forward the underlying TCP
bytes identically — the point being that any protocol built on TCP works,
not just the exact strings `tcp` / `http`.
"""
import hashlib
import http.server
import json
import os
import socket
import subprocess
import sys
import threading
import time
import urllib.request


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NODE_A_CONFIG = os.path.join(ROOT, "tests", "dynamic_forward_node_a.jsonc")
NODE_B_CONFIG = os.path.join(ROOT, "tests", "dynamic_forward_node_b.jsonc")
NODE_A_WEB = "127.0.0.1:19200"
NODE_B_WEB = "127.0.0.1:19201"
BENCH_PORT = 19480
BENCH_PATH = "/bench"
PAYLOAD_SIZE = 1 * 1024 * 1024
NODE_PORTS = [16201, 16202, 19200, 19201]
PORT_MAPPINGS_STORE = os.path.expanduser("~/.msgtier/port_mappings.json")


def log(msg):
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def is_port_open(port, host="127.0.0.1"):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.2)
        return sock.connect_ex((host, port)) == 0


def cleanup():
    subprocess.run(["pkill", "-f", "moon run cmd/main"], stderr=subprocess.DEVNULL)
    for _ in range(40):
        if all(not is_port_open(port) for port in NODE_PORTS):
            return
        time.sleep(0.25)


def wipe_mapping_store():
    """Remove any persisted port_mappings.json so runs are hermetic."""
    try:
        os.remove(PORT_MAPPINGS_STORE)
    except FileNotFoundError:
        pass
    except OSError as e:
        log(f"warn: could not remove {PORT_MAPPINGS_STORE}: {e}")


def run_node(config_file, log_file):
    cmd = ["moon", "run", "cmd/main", "--debug", "--", config_file]
    f = open(log_file, "w", buffering=1)
    process = subprocess.Popen(
        cmd, stdout=f, stderr=subprocess.STDOUT, text=True, cwd=ROOT
    )
    return process, f


def http_request(url, method="GET", body=None, timeout=5):
    """Return (status, body_dict_or_none). Failure → (0, None)."""
    data = body.encode("utf-8") if body else None
    headers = {"Content-Type": "application/json"} if body else {}
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8")
            try:
                return resp.getcode(), json.loads(raw)
            except json.JSONDecodeError:
                return resp.getcode(), raw
    except urllib.error.HTTPError as e:
        try:
            raw = e.read().decode("utf-8")
        except Exception:
            raw = ""
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, raw
    except Exception:
        return 0, None


def wait_http_ready(url, attempts=120, delay=0.25, method="GET"):
    for _ in range(attempts):
        status, _ = http_request(url, method=method, timeout=2)
        if status == 200:
            return True
        time.sleep(delay)
    return False


def wait_peer_connected(status_url, peer_id, attempts=120, delay=0.5):
    for _ in range(attempts):
        status, body = http_request(status_url, timeout=2)
        if status == 200 and isinstance(body, dict):
            for peer in body.get("peers", []):
                if peer.get("id") == peer_id and peer.get("connections"):
                    return True
        time.sleep(delay)
    return False


def wait_peer_port_scan(peers_url, peer_id, protocol, port,
                       attempts=180, delay=0.5):
    """Poll GET /api/port_scan/peers until (peer_id, protocol, port) shows up.

    Scanner runs every 30 s, so give it up to ~90 s.
    """
    for _ in range(attempts):
        status, body = http_request(peers_url, timeout=2)
        if status == 200 and isinstance(body, dict):
            peers = body.get("peers", {})
            entry = peers.get(peer_id)
            if entry:
                for p in entry.get("ports", []):
                    if p.get("protocol") == protocol and p.get("port") == port:
                        return True
        time.sleep(delay)
    return False


class StreamingServer:
    def __init__(self, host, port, payload):
        self.host = host
        self.port = port
        self.payload = payload
        self.stop_event = threading.Event()
        self.thread = None
        self.server = None

    def start(self):
        payload = self.payload

        class Handler(http.server.BaseHTTPRequestHandler):
            def handle_bench_request(self, write_body):
                if self.path != BENCH_PATH:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                if write_body:
                    try:
                        self.wfile.write(payload)
                    except (BrokenPipeError, ConnectionResetError):
                        return

            def do_HEAD(self):
                self.handle_bench_request(False)

            def do_GET(self):
                self.handle_bench_request(True)

            def log_message(self, format, *args):
                return

        class ReusableThreadingHTTPServer(http.server.ThreadingHTTPServer):
            allow_reuse_address = True

        def run():
            self.server = ReusableThreadingHTTPServer((self.host, self.port), Handler)
            self.server.timeout = 0.5
            while not self.stop_event.is_set():
                self.server.handle_request()

        self.thread = threading.Thread(target=run, daemon=True)
        self.thread.start()

    def stop(self):
        self.stop_event.set()
        if self.server is not None:
            self.server.server_close()
        if self.thread is not None:
            self.thread.join(timeout=1)


def create_mapping(web_api, peer_id, protocol, remote_port):
    """POST /api/port_mappings. Returns (status, response_dict_or_raw)."""
    url = f"http://{web_api}/api/port_mappings"
    body = json.dumps({
        "peer_id": peer_id,
        "remote_protocol": protocol,
        "remote_port": remote_port,
    })
    return http_request(url, method="POST", body=body, timeout=5)


def delete_mapping(web_api, mapping_id):
    url = f"http://{web_api}/api/port_mappings/{mapping_id}"
    return http_request(url, method="DELETE", timeout=5)


def download_once(url, expected_size):
    with urllib.request.urlopen(url, timeout=30) as resp:
        if resp.getcode() != 200:
            raise RuntimeError(f"expected 200, got {resp.getcode()}")
        received = resp.read()
    if len(received) != expected_size:
        raise RuntimeError(f"expected {expected_size} bytes, got {len(received)}")
    return received


def try_protocol(web_api, protocol, expected_hash):
    """Return (label, ok, detail).

    label ∈ {"OK", "REJECTED", "TIMEOUT", "MISMATCH", "MAPPING_FAILED", ...}
    """
    log(f"protocol={protocol}: creating mapping")
    status, body = create_mapping(web_api, "node-b", protocol, BENCH_PORT)
    if status != 200 or not isinstance(body, dict):
        return ("MAPPING_FAILED", False, f"status={status} body={body}")

    mapping_id = body.get("id")
    local_port = body.get("local_port")
    if not mapping_id or not local_port:
        return ("MAPPING_FAILED", False, f"malformed response: {body}")

    log(f"protocol={protocol}: mapping_id={mapping_id} local_port={local_port}")

    forward_url = f"http://127.0.0.1:{local_port}{BENCH_PATH}"
    try:
        if not wait_http_ready(forward_url, attempts=60, delay=0.5, method="HEAD"):
            return ("TIMEOUT", False,
                    f"forward listener at {forward_url} never returned 200 to HEAD")

        try:
            received = download_once(forward_url, PAYLOAD_SIZE)
        except Exception as e:
            return ("REJECTED", False, f"download failed: {e}")

        got_hash = hashlib.sha256(received).hexdigest()
        if got_hash != expected_hash:
            return ("MISMATCH", False,
                    f"payload hash mismatch: got {got_hash[:16]}… want {expected_hash[:16]}…")
        return ("OK", True, f"downloaded {PAYLOAD_SIZE} bytes via port {local_port}")
    finally:
        del_status, del_body = delete_mapping(web_api, mapping_id)
        log(f"protocol={protocol}: DELETE mapping status={del_status}")


def main():
    cleanup()
    wipe_mapping_store()

    payload = (b"msgtier-dynamic-port-forward-test-" * (PAYLOAD_SIZE // 34 + 1))[:PAYLOAD_SIZE]
    expected_hash = hashlib.sha256(payload).hexdigest()

    origin = StreamingServer("0.0.0.0", BENCH_PORT, payload)
    origin.start()

    p_a = p_b = None
    f_a = f_b = None
    exit_code = 1
    try:
        log("starting node-b")
        p_b, f_b = run_node(
            NODE_B_CONFIG,
            os.path.join(ROOT, "tests", "dynamic-port-forward-node-b.log"),
        )
        if not wait_http_ready(f"http://{NODE_B_WEB}/api/config"):
            print("FAILURE: node-b http not ready")
            return 1

        log("starting node-a")
        p_a, f_a = run_node(
            NODE_A_CONFIG,
            os.path.join(ROOT, "tests", "dynamic-port-forward-node-a.log"),
        )
        if not wait_http_ready(f"http://{NODE_A_WEB}/api/config"):
            print("FAILURE: node-a http not ready")
            return 1

        log("waiting for node-a to connect to node-b")
        if not wait_peer_connected(f"http://{NODE_A_WEB}/api/status", "node-b"):
            print("FAILURE: node-a did not connect to node-b")
            return 1

        # Force a scan on node-b so we don't have to wait 30 s for the first tick.
        log("kicking node-b's port scanner")
        http_request(f"http://{NODE_B_WEB}/api/port_scan/refresh",
                     method="POST", timeout=5)

        log(f"waiting for node-a to see tcp:{BENCH_PORT} in node-b's port scan")
        if not wait_peer_port_scan(
            f"http://{NODE_A_WEB}/api/port_scan/peers",
            "node-b", "tcp", BENCH_PORT,
        ):
            print(f"FAILURE: node-a never saw tcp:{BENCH_PORT} in node-b's port list")
            return 1
        log("port scan visible; proceeding to mapping tests")

        results = {}
        # tcp: baseline; http/https/ws: common TCP-based application labels;
        # custom-proto: arbitrary user label — must be treated as TCP by default.
        for protocol in ["tcp", "http", "https", "ws", "custom-proto"]:
            label, ok, detail = try_protocol(NODE_A_WEB, protocol, expected_hash)
            results[protocol] = (label, ok, detail)
            log(f"protocol={protocol}: {label} — {detail}")

        summary = " ".join(f"{p}={label}" for p, (label, _, _) in results.items())
        print(f"RESULT: {summary}")

        failed = [p for p, (_, ok, _) in results.items() if not ok]
        if failed:
            for p in failed:
                print(f"FAILURE: {p} forward failed — {results[p][2]}")
            return 1

        exit_code = 0
        return 0
    finally:
        log("shutting down")
        if p_a:
            p_a.terminate()
        if p_b:
            p_b.terminate()
        if f_a:
            f_a.close()
        if f_b:
            f_b.close()
        origin.stop()
        time.sleep(1)
        cleanup()
        wipe_mapping_store()
        log(f"exit code: {exit_code}")


if __name__ == "__main__":
    sys.exit(main())
