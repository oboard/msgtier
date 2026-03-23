import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.request
import urllib.error
import hashlib


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NODE_A_CONFIG = os.path.join(ROOT, "tests", "port_forward_node_a.jsonc")
NODE_B_CONFIG = os.path.join(ROOT, "tests", "port_forward_node_b.jsonc")
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


class TcpEchoServer:
    def __init__(self, host, port):
        self.host = host
        self.port = port
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
                conn.settimeout(2)
                threading.Thread(target=self.handle_conn, args=(conn,), daemon=True).start()

        self.thread = threading.Thread(target=run, daemon=True)
        self.thread.start()

    def handle_conn(self, conn):
        with conn:
            while not self.stop_event.is_set():
                try:
                    data = conn.recv(65536)
                except socket.timeout:
                    continue
                if not data:
                    return
                conn.sendall(data)

    def stop(self):
        self.stop_event.set()
        if self.server is not None:
            self.server.close()
        if self.thread is not None:
            self.thread.join(timeout=1)


class UdpEchoServer:
    def __init__(self, host, port):
        self.host = host
        self.port = port
        self.stop_event = threading.Event()
        self.thread = None
        self.sock = None

    def start(self):
        def run():
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.sock.bind((self.host, self.port))
            self.sock.settimeout(0.5)
            while not self.stop_event.is_set():
                try:
                    data, addr = self.sock.recvfrom(65536)
                except socket.timeout:
                    continue
                self.sock.sendto(data, addr)

        self.thread = threading.Thread(target=run, daemon=True)
        self.thread.start()

    def stop(self):
        self.stop_event.set()
        if self.sock is not None:
            self.sock.close()
        if self.thread is not None:
            self.thread.join(timeout=1)


def recv_exact(sock, size):
    chunks = []
    remaining = size
    while remaining > 0:
        chunk = sock.recv(remaining)
        if not chunk:
            raise RuntimeError(f"expected {size} bytes, got {size - remaining}")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def describe_mismatch(expected, actual, limit=32):
    if len(expected) != len(actual):
        return (
            f"length expected={len(expected)} actual={len(actual)} "
            f"expected_sha256={hashlib.sha256(expected).hexdigest()} "
            f"actual_sha256={hashlib.sha256(actual).hexdigest()}"
        )
    for idx, (lhs, rhs) in enumerate(zip(expected, actual)):
        if lhs != rhs:
            start = max(0, idx - limit)
            end = min(len(expected), idx + limit)
            return (
                f"offset={idx} expected_byte={lhs} actual_byte={rhs} "
                f"expected_sha256={hashlib.sha256(expected).hexdigest()} "
                f"actual_sha256={hashlib.sha256(actual).hexdigest()} "
                f"expected_slice={expected[start:end].hex()} "
                f"actual_slice={actual[start:end].hex()}"
            )
    return "payload differs but mismatch offset not found"


def main():
    cleanup()
    tcp_server = TcpEchoServer("127.0.0.1", 19432)
    udp_server = UdpEchoServer("127.0.0.1", 19053)
    tcp_server.start()
    udp_server.start()

    p1 = p2 = None
    f1 = f2 = None
    try:
        p1, f1 = run_node(NODE_A_CONFIG, os.path.join(ROOT, "tests", "port-forward-node-a.log"))
        if not wait_http_ready("http://127.0.0.1:19100/api/config"):
            print("FAILURE: node-a http not ready")
            return 1

        p2, f2 = run_node(NODE_B_CONFIG, os.path.join(ROOT, "tests", "port-forward-node-b.log"))
        if not wait_http_ready("http://127.0.0.1:19101/api/config"):
            print("FAILURE: node-b http not ready")
            return 1

        if not wait_peer_connected("http://127.0.0.1:19100/api/status", "node-b"):
            print("FAILURE: node-a not connected to node-b")
            return 1

        time.sleep(1)

        tcp_payload = (b"db-tunnel-" * 8192) + bytes(range(64))
        with socket.create_connection(("127.0.0.1", 15432), timeout=10) as conn:
            conn.sendall(tcp_payload)
            tcp_echo = recv_exact(conn, len(tcp_payload))
        if tcp_echo != tcp_payload:
            print(f"FAILURE: tcp forward payload mismatch {describe_mismatch(tcp_payload, tcp_echo)}")
            return 1
        log(f"tcp ok bytes={len(tcp_payload)}")

        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.settimeout(10)
            for idx in range(3):
                udp_payload = ((b"dns-tunnel-" * 256) + bytes([65 + idx]))
                sock.sendto(udp_payload, ("127.0.0.1", 1053))
                udp_echo, _ = sock.recvfrom(65536)
                if udp_echo != udp_payload:
                    print(f"FAILURE: udp forward payload mismatch round={idx + 1}")
                    return 1
                log(f"udp ok round={idx + 1} bytes={len(udp_payload)}")

        print("SUCCESS: local port forwarding works for tcp and udp")
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
        tcp_server.stop()
        udp_server.stop()
        time.sleep(1)
        cleanup()


if __name__ == "__main__":
    sys.exit(main())
