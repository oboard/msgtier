import hashlib
import os
import socket
import statistics
import subprocess
import sys
import threading
import time
import urllib.request
import json


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NODE_A_CONFIG = os.path.join(ROOT, "tests", "port_forward_node_a.jsonc")
NODE_B_CONFIG = os.path.join(ROOT, "tests", "port_forward_node_b.jsonc")
BENCH_PORT = 19480
FORWARD_PORT = 18081
PAYLOAD_SIZE = 16 * 1024 * 1024
ROUNDS = 3


def log(msg):
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def cleanup():
    subprocess.run(["pkill", "-f", "moon run cmd/main"], stderr=subprocess.DEVNULL)
    time.sleep(1)


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


def wait_http_ready(url, attempts=120, delay=0.25):
    for _ in range(attempts):
        status, _ = get_json(url)
        if status == 200:
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
        def run():
            self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self.server.bind((self.host, self.port))
            self.server.listen()
            self.server.settimeout(0.5)
            while not self.stop_event.is_set():
                try:
                    conn, _ = self.server.accept()
                except socket.timeout:
                    continue
                threading.Thread(target=self.handle_conn, args=(conn,), daemon=True).start()

        self.thread = threading.Thread(target=run, daemon=True)
        self.thread.start()

    def handle_conn(self, conn):
        with conn:
            conn.sendall(self.payload)

    def stop(self):
        self.stop_event.set()
        if self.server is not None:
            self.server.close()
        if self.thread is not None:
            self.thread.join(timeout=1)


def download_once(port, expected_size):
    start = time.perf_counter()
    received = b""
    with socket.create_connection(("127.0.0.1", port), timeout=10) as conn:
        while len(received) < expected_size:
            chunk = conn.recv(65536)
            if not chunk:
                break
            received += chunk
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
    server = StreamingServer("127.0.0.1", BENCH_PORT, payload)
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

        direct_speeds = []
        forward_speeds = []
        for round_idx in range(ROUNDS):
            elapsed, received = download_once(BENCH_PORT, PAYLOAD_SIZE)
            if hashlib.sha256(received).hexdigest() != payload_hash:
                print("FAILURE: direct payload hash mismatch")
                return 1
            direct = mib_per_sec(PAYLOAD_SIZE, elapsed)
            direct_speeds.append(direct)
            log(f"direct round={round_idx + 1} speed={direct:.2f} MiB/s")

            elapsed, received = download_once(FORWARD_PORT, PAYLOAD_SIZE)
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
