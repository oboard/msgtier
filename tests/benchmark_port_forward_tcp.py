"""TCP port-forward throughput benchmark.

Measures MB/s through the msgtier port-forward tunnel end-to-end:
  1. Start node-a (requester) and node-b (exposer) with the dynamic-forward configs.
  2. Start a plain TCP server on node-b's side that streams a fixed payload.
  3. Create a port mapping via POST /api/port_mappings on node-a.
  4. Download through the tunnel N times and report per-round and average MB/s.

Usage:
    python3 tests/benchmark_port_forward_tcp.py [--size-mb 64] [--rounds 3]
"""

import argparse
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
import urllib.error


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NODE_A_CONFIG = os.path.join(ROOT, "tests", "dynamic_forward_node_a.jsonc")
NODE_B_CONFIG = os.path.join(ROOT, "tests", "dynamic_forward_node_b.jsonc")
NODE_A_WEB = "127.0.0.1:19200"
NODE_B_WEB = "127.0.0.1:19201"
BENCH_PORT = 19480
BENCH_PATH = "/bench"
NODE_PORTS = [16201, 16202, 19200, 19201]
PORT_MAPPINGS_STORE = os.path.expanduser("~/.msgtier/port_mappings.json")


def log(msg):
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def is_port_open(port, host="127.0.0.1"):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.2)
        return s.connect_ex((host, port)) == 0


def cleanup():
    subprocess.run(["pkill", "-f", "moon run cmd/main"], stderr=subprocess.DEVNULL)
    for _ in range(40):
        if all(not is_port_open(p) for p in NODE_PORTS):
            return
        time.sleep(0.25)


def wipe_mapping_store():
    try:
        os.remove(PORT_MAPPINGS_STORE)
    except FileNotFoundError:
        pass


def run_node(config_file, log_file):
    cmd = ["moon", "run", "cmd/main", "--debug", "--", config_file]
    f = open(log_file, "w", buffering=1)
    proc = subprocess.Popen(cmd, stdout=f, stderr=subprocess.STDOUT, text=True, cwd=ROOT)
    return proc, f


def http_request(url, method="GET", body=None, timeout=5):
    data = body.encode() if body else None
    headers = {"Content-Type": "application/json"} if body else {}
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode()
            try:
                return resp.getcode(), json.loads(raw)
            except json.JSONDecodeError:
                return resp.getcode(), raw
    except urllib.error.HTTPError as e:
        try:
            raw = e.read().decode()
        except Exception:
            raw = ""
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, raw
    except Exception:
        return 0, None


def wait_http_ready(url, attempts=120, delay=0.25):
    for _ in range(attempts):
        status, _ = http_request(url, timeout=2)
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


def wait_peer_port_scan(peers_url, peer_id, protocol, port, attempts=180, delay=0.5):
    for _ in range(attempts):
        status, body = http_request(peers_url, timeout=2)
        if status == 200 and isinstance(body, dict):
            entry = body.get("peers", {}).get(peer_id)
            if entry:
                for p in entry.get("ports", []):
                    if p.get("protocol") == protocol and p.get("port") == port:
                        return True
        time.sleep(delay)
    return False


class PayloadServer:
    """HTTP server that serves a fixed payload on GET /bench."""

    def __init__(self, host, port, payload):
        self.host = host
        self.port = port
        self.payload = payload
        self._stop = threading.Event()
        self._thread = None
        self._server = None

    def start(self):
        payload = self.payload

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_HEAD(self):
                if self.path != BENCH_PATH:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()

            def do_GET(self):
                if self.path != BENCH_PATH:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                try:
                    self.wfile.write(payload)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def log_message(self, *_):
                pass

        class Server(http.server.ThreadingHTTPServer):
            allow_reuse_address = True

        stop = self._stop

        def run():
            self._server = Server((self.host, self.port), Handler)
            self._server.timeout = 0.5
            while not stop.is_set():
                self._server.handle_request()

        self._thread = threading.Thread(target=run, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        if self._server:
            self._server.server_close()
        if self._thread:
            self._thread.join(timeout=2)


def create_mapping(web_api, peer_id, remote_port, protocol="tcp"):
    url = f"http://{web_api}/api/port_mappings"
    body = json.dumps({"peer_id": peer_id, "remote_protocol": protocol, "remote_port": remote_port})
    return http_request(url, method="POST", body=body, timeout=5)


def delete_mapping(web_api, mapping_id):
    return http_request(f"http://{web_api}/api/port_mappings/{mapping_id}", method="DELETE", timeout=5)


def download_payload(url, expected_size, timeout=120):
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        if resp.getcode() != 200:
            raise RuntimeError(f"HTTP {resp.getcode()}")
        data = resp.read()
    if len(data) != expected_size:
        raise RuntimeError(f"size mismatch: got {len(data)}, want {expected_size}")
    return data


def wait_tunnel_ready(local_port, attempts=60, delay=0.5):
    url = f"http://127.0.0.1:{local_port}{BENCH_PATH}"
    for _ in range(attempts):
        status, _ = http_request(url, method="HEAD", timeout=3)
        if status == 200:
            return True
        time.sleep(delay)
    return False


def run_benchmark(size_mb, rounds):
    payload_size = size_mb * 1024 * 1024
    payload = (b"msgtier-port-forward-bench-" * (payload_size // 27 + 1))[:payload_size]
    expected_hash = hashlib.sha256(payload).hexdigest()

    cleanup()
    wipe_mapping_store()

    origin = PayloadServer("0.0.0.0", BENCH_PORT, payload)
    origin.start()

    p_a = p_b = f_a = f_b = None
    mapping_id = None
    local_port = None

    try:
        log(f"starting node-b")
        p_b, f_b = run_node(NODE_B_CONFIG, os.path.join(ROOT, "tests", "bench-pf-node-b.log"))
        if not wait_http_ready(f"http://{NODE_B_WEB}/api/config"):
            print("FAILURE: node-b not ready")
            return False

        log("starting node-a")
        p_a, f_a = run_node(NODE_A_CONFIG, os.path.join(ROOT, "tests", "bench-pf-node-a.log"))
        if not wait_http_ready(f"http://{NODE_A_WEB}/api/config"):
            print("FAILURE: node-a not ready")
            return False

        log("waiting for peer connection")
        if not wait_peer_connected(f"http://{NODE_A_WEB}/api/status", "node-b"):
            print("FAILURE: peer not connected")
            return False

        log("kicking node-b port scanner")
        http_request(f"http://{NODE_B_WEB}/api/port_scan/refresh", method="POST", timeout=5)

        log(f"waiting for node-a to see tcp:{BENCH_PORT} in node-b's port list")
        if not wait_peer_port_scan(f"http://{NODE_A_WEB}/api/port_scan/peers", "node-b", "tcp", BENCH_PORT):
            print(f"FAILURE: port {BENCH_PORT} not visible in node-b's scan")
            return False

        log("creating port mapping")
        status, body = create_mapping(NODE_A_WEB, "node-b", BENCH_PORT)
        if status != 200 or not isinstance(body, dict):
            print(f"FAILURE: create mapping status={status} body={body}")
            return False
        mapping_id = body.get("id")
        local_port = body.get("local_port")
        if not mapping_id or not local_port:
            print(f"FAILURE: malformed mapping response: {body}")
            return False
        log(f"mapping id={mapping_id} local_port={local_port}")

        log("waiting for tunnel to be ready")
        if not wait_tunnel_ready(local_port):
            print(f"FAILURE: tunnel at port {local_port} never responded")
            return False

        tunnel_url = f"http://127.0.0.1:{local_port}{BENCH_PATH}"
        print(f"\n{'='*60}")
        print(f"  TCP port-forward throughput  ({size_mb} MB x {rounds} rounds)")
        print(f"  tunnel: localhost:{local_port}  ->  node-b:{BENCH_PORT}")
        print(f"{'='*60}")

        times = []
        for i in range(1, rounds + 1):
            t0 = time.perf_counter()
            data = download_payload(tunnel_url, payload_size)
            t1 = time.perf_counter()
            elapsed = t1 - t0
            mbps = payload_size / 1024 / 1024 / elapsed
            got_hash = hashlib.sha256(data).hexdigest()
            if got_hash != expected_hash:
                print(f"FAILURE: round {i} hash mismatch")
                return False
            times.append(elapsed)
            print(f"  Round {i}: {mbps:.2f} MB/s  ({elapsed*1000:.0f} ms)")

        avg = sum(times) / len(times)
        avg_mbps = payload_size / 1024 / 1024 / avg
        min_mbps = payload_size / 1024 / 1024 / max(times)
        max_mbps = payload_size / 1024 / 1024 / min(times)
        print(f"{'='*60}")
        print(f"  avg={avg_mbps:.2f} MB/s  min={min_mbps:.2f}  max={max_mbps:.2f}")
        print(f"{'='*60}\n")
        return True

    finally:
        if mapping_id:
            delete_mapping(NODE_A_WEB, mapping_id)
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


def main():
    parser = argparse.ArgumentParser(description="TCP port-forward throughput benchmark")
    parser.add_argument("--size-mb", type=int, default=64, help="payload size in MB (default: 64)")
    parser.add_argument("--rounds", type=int, default=3, help="number of rounds (default: 3)")
    args = parser.parse_args()

    ok = run_benchmark(args.size_mb, args.rounds)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
