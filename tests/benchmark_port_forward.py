import hashlib
import http.server
import os
import socket
import statistics
import subprocess
import sys
import threading
import time
import json
import urllib.request


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NODE_A_CONFIG = os.path.join(ROOT, "tests", "port_forward_node_a.jsonc")
NODE_B_CONFIG = os.path.join(ROOT, "tests", "port_forward_node_b.jsonc")
BENCH_PORT = 19480
FORWARD_PORT = 18081
PAYLOAD_SIZE = 16 * 1024 * 1024
ROUNDS = 3
BENCH_PATH = "/bench"
NODE_PORTS = [16101, 16102, 19100, 19101]


def log(msg):
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def cleanup():
    subprocess.run(["pkill", "-f", "moon run cmd/main"], stderr=subprocess.DEVNULL)
    for _ in range(40):
        if all(not is_port_open(port) for port in NODE_PORTS):
            return
        time.sleep(0.25)


def is_port_open(port, host="127.0.0.1"):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.2)
        return sock.connect_ex((host, port)) == 0


def run_node(config_file, log_file):
    cmd = ["moon", "run", "cmd/main", "--debug", "--", config_file]
    f = open(log_file, "w", buffering=1)
    process = subprocess.Popen(cmd, stdout=f, stderr=subprocess.STDOUT, text=True)
    return process, f


def get_json(url, timeout=2):
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.getcode(), json.loads(resp.read().decode("utf-8"))
    except Exception:
        return 0, None


def get_status(url, timeout=2, method="GET"):
    req = urllib.request.Request(url, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.getcode()
    except Exception:
        return 0


def wait_http_ready(url, attempts=120, delay=0.25, method="GET"):
    for _ in range(attempts):
        if get_status(url, method=method) == 200:
            return True
        time.sleep(delay)
    return False


def wait_peer_connected(status_url, peer_id, attempts=120, delay=0.5):
    for _ in range(attempts):
        status, body = get_json(status_url)
        if status == 200 and body:
            for peer in body.get("peers", []):
                if peer.get("id") == peer_id and peer.get("connections"):
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


def download_once(url, expected_size):
    start = time.perf_counter()
    with urllib.request.urlopen(url, timeout=30) as resp:
        if resp.getcode() != 200:
            raise RuntimeError(f"expected 200, got {resp.getcode()}")
        received = resp.read()
    elapsed = time.perf_counter() - start
    if len(received) != expected_size:
        raise RuntimeError(f"expected {expected_size} bytes, got {len(received)}")
    return elapsed, received


def mib_per_sec(size_bytes, elapsed):
    return size_bytes / 1024 / 1024 / elapsed


def main():
    cleanup()
    payload = (b"msgtier-port-forward-bench-" * (PAYLOAD_SIZE // 27 + 1))[:PAYLOAD_SIZE]
    payload_hash = hashlib.sha256(payload).hexdigest()
    direct_url = f"http://127.0.0.1:{BENCH_PORT}{BENCH_PATH}"
    forward_url = f"http://127.0.0.1:{FORWARD_PORT}{BENCH_PATH}"
    server = StreamingServer("0.0.0.0", BENCH_PORT, payload)
    server.start()

    p1 = p2 = None
    f1 = f2 = None
    try:
        p1, f1 = run_node(NODE_A_CONFIG, os.path.join(ROOT, "tests", "bench-port-forward-node-a.log"))
        if not wait_http_ready("http://127.0.0.1:19100/api/config"):
            print("FAILURE: node-a http not ready")
            return 1

        p2, f2 = run_node(NODE_B_CONFIG, os.path.join(ROOT, "tests", "bench-port-forward-node-b.log"))
        if not wait_http_ready("http://127.0.0.1:19101/api/config"):
            print("FAILURE: node-b http not ready")
            return 1

        if not wait_peer_connected("http://127.0.0.1:19100/api/status", "node-b"):
            print("FAILURE: node-a not connected to node-b")
            return 1

        time.sleep(1)
        if not wait_http_ready(direct_url, method="HEAD"):
            print("FAILURE: direct bench http not ready")
            return 1
        if not wait_http_ready(forward_url, attempts=240, delay=0.5, method="HEAD"):
            print("FAILURE: forwarded bench http not ready")
            return 1

        direct_speeds = []
        forward_speeds = []
        for round_idx in range(ROUNDS):
            elapsed, received = download_once(direct_url, PAYLOAD_SIZE)
            if hashlib.sha256(received).hexdigest() != payload_hash:
                print("FAILURE: direct payload hash mismatch")
                return 1
            direct = mib_per_sec(PAYLOAD_SIZE, elapsed)
            direct_speeds.append(direct)
            log(f"direct round={round_idx + 1} speed={direct:.2f} MiB/s")

            elapsed, received = download_once(forward_url, PAYLOAD_SIZE)
            if hashlib.sha256(received).hexdigest() != payload_hash:
                print("FAILURE: forwarded payload hash mismatch")
                return 1
            forwarded = mib_per_sec(PAYLOAD_SIZE, elapsed)
            forward_speeds.append(forwarded)
            log(f"forward round={round_idx + 1} speed={forwarded:.2f} MiB/s")

        direct_avg = statistics.mean(direct_speeds)
        forward_avg = statistics.mean(forward_speeds)
        ratio = forward_avg / direct_avg if direct_avg > 0 else 0.0

        print(
            f"RESULT direct_avg={direct_avg:.2f}MiB/s "
            f"forward_avg={forward_avg:.2f}MiB/s ratio={ratio:.2%}"
        )

        if forward_avg < 1.0:
            print("FAILURE: forwarded throughput is unexpectedly low")
            return 1

        return 0
    finally:
        if p1:
            p1.terminate()
        if p2:
            p2.terminate()
        if f1:
            f1.close()
        if f2:
            f2.close()
        server.stop()
        time.sleep(1)
        cleanup()


if __name__ == "__main__":
    sys.exit(main())
