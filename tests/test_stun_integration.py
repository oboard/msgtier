import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NODE1_CONFIG = os.path.join(ROOT, "config", "1.jsonc")
NODE2_CONFIG = os.path.join(ROOT, "config", "2.jsonc")
NODE1_STATUS = "http://127.0.0.1:9000/api/status"
NODE2_STATUS = "http://127.0.0.1:9001/api/status"
NODE1_SEND = "http://127.0.0.1:9000/api/send"


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


def wait_status_stun(url, listener_url, attempts=120, delay=0.25):
    for _ in range(attempts):
        status, body = get_json(url)
        if status == 200 and body:
            for entry in body.get("stun", []):
                if entry.get("listener") == listener_url:
                    return entry
        time.sleep(delay)
    return None


def assert_stun_entry(entry, listener_url):
    if entry is None:
        raise RuntimeError(f"missing STUN entry for {listener_url}")
    if entry.get("listener") != listener_url:
        raise RuntimeError(f"unexpected listener in STUN entry: {entry}")
    if "updated_at" not in entry:
        raise RuntimeError(f"missing updated_at in STUN entry: {entry}")
    if "supports_rfc5780" not in entry:
        raise RuntimeError(f"missing supports_rfc5780 in STUN entry: {entry}")
    public_address = entry.get("public_address")
    if public_address is not None and not public_address.startswith("udp://"):
        raise RuntimeError(f"unexpected public_address in STUN entry: {entry}")


def wait_peer_connected(status_url, peer_id, attempts=120, delay=0.5):
    for _ in range(attempts):
        status, body = get_json(status_url)
        if status == 200 and body:
            for peer in body.get("peers", []):
                if peer.get("id") == peer_id and peer.get("connections"):
                    return True
        time.sleep(delay)
    return False


def main():
    cleanup()
    p1 = p2 = None
    f1 = f2 = None
    try:
        p1, f1 = run_node(NODE1_CONFIG, os.path.join(ROOT, "tests", "stun-node1.log"))
        p2, f2 = run_node(NODE2_CONFIG, os.path.join(ROOT, "tests", "stun-node2.log"))

        log("waiting for node HTTP APIs")
        if not wait_http_ready(NODE1_STATUS):
            raise RuntimeError("node1 http not ready")
        if not wait_http_ready(NODE2_STATUS):
            raise RuntimeError("node2 http not ready")

        log("waiting for STUN discovery snapshots")
        node1_stun = wait_status_stun(NODE1_STATUS, "udp://0.0.0.0:6666")
        node2_stun = wait_status_stun(NODE2_STATUS, "udp://0.0.0.0:7001")
        assert_stun_entry(node1_stun, "udp://0.0.0.0:6666")
        assert_stun_entry(node2_stun, "udp://0.0.0.0:7001")

        log("waiting for peers to connect")
        if not wait_peer_connected(NODE1_STATUS, "oboard-mac-2"):
            raise RuntimeError("node1 did not connect to node2")

        log("sending integration request")
        headers = {"target": "oboard-mac", "Content-Type": "text/plain"}
        data = "fastfetch".encode("utf-8")
        req = urllib.request.Request(NODE1_SEND, data=data, headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=10) as response:
            status_code = response.getcode()
            response_text = response.read().decode("utf-8")

        if status_code != 200:
            raise RuntimeError(f"unexpected status code: {status_code}")
        if "error" in response_text.lower():
            raise RuntimeError(f"unexpected error response: {response_text}")
        if not response_text:
            raise RuntimeError("empty response body")

        log("stun integration test passed")
        return 0
    except urllib.error.HTTPError as e:
        log(f"HTTP error: {e.code} - {e.read().decode('utf-8')}")
        return 1
    except urllib.error.URLError as e:
        log(f"URL error: {e.reason}")
        return 1
    except Exception as e:
        log(f"failure: {e}")
        return 1
    finally:
        log("stopping nodes")
        if p1:
            p1.terminate()
        if p2:
            p2.terminate()
        if f1:
            f1.close()
        if f2:
            f2.close()
        time.sleep(1)
        cleanup()


if __name__ == "__main__":
    sys.exit(main())
