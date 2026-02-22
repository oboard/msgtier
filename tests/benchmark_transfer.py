import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


def cleanup():
    subprocess.run(["pkill", "-f", "moon run cmd/main"], stderr=subprocess.DEVNULL)
    time.sleep(1)


def run_node(config_file, log_file):
    cmd = ["moon", "run", "cmd/main", "--debug", "--", config_file]
    f = open(log_file, "w", buffering=1)
    process = subprocess.Popen(cmd, stdout=f, stderr=subprocess.STDOUT, text=True)
    return process, f


def post_bytes(url, data, headers=None, timeout=30):
    req_headers = {"Content-Type": "application/octet-stream"}
    if headers:
        req_headers.update(headers)
    req = urllib.request.Request(url, data=data, headers=req_headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.getcode(), resp.read(), dict(resp.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers)
    except (urllib.error.URLError, TimeoutError, OSError):
        return 0, b"", {}


def get_bytes(url, timeout=60):
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.getcode(), resp.read(), dict(resp.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers)
    except (urllib.error.URLError, TimeoutError, OSError):
        return 0, b"", {}


def wait_http_ready(url, attempts=60, delay=0.2):
    for _ in range(attempts):
        status, _, _ = get_bytes(url, timeout=2)
        if status == 200:
            return True
        time.sleep(delay)
    return False


def wait_peer_connected(status_url, peer_id, attempts=120, delay=0.5):
    for _ in range(attempts):
        status, body, _ = get_bytes(status_url, timeout=2)
        if status == 200 and body:
            try:
                info = json.loads(body.decode("utf-8"))
                for peer in info.get("peers", []):
                    if peer.get("id") == peer_id and peer.get("connections"):
                        return True
            except Exception:
                pass
        time.sleep(delay)
    return False


def build_payload(size_bytes):
    base = b"msgtier-benchmark-payload-"
    if size_bytes <= len(base):
        return base[:size_bytes]
    repeat = size_bytes // len(base) + 1
    payload = base * repeat
    return payload[:size_bytes]


def format_mbps(bytes_count, seconds):
    if seconds <= 0:
        return 0.0
    return bytes_count / 1024 / 1024 / seconds


def benchmark(payload_size, rounds, peer_id, node1_url, node2_url):
    cleanup()
    p1 = None
    p2 = None
    f1 = None
    f2 = None

    try:
        p1, f1 = run_node("config/1.jsonc", "tests/node1.log")
        if not wait_http_ready(f"{node1_url}/api/config"):
            print("FAILURE: Node 1 HTTP not ready")
            return False

        p2, f2 = run_node("config/2.jsonc", "tests/node2.log")
        if not wait_http_ready(f"{node2_url}/api/config"):
            print("FAILURE: Node 2 HTTP not ready")
            return False
        if not wait_peer_connected(f"{node2_url}/api/status", peer_id):
            print(f"FAILURE: peer {peer_id} not connected on node2")
            return False

        payload = build_payload(payload_size)
        upload_url = f"{node1_url}/api/object"

        upload_times = []
        download_times = []

        for i in range(1, rounds + 1):
            t0 = time.perf_counter()
            status, body, _ = post_bytes(upload_url, payload, timeout=60)
            t1 = time.perf_counter()
            if status != 200:
                print(f"FAILURE: upload status={status} body_len={len(body)}")
                return False

            try:
                obj = json.loads(body.decode("utf-8"))
                object_id = obj.get("id", "")
            except Exception as e:
                print(f"FAILURE: cannot parse upload response: {e}")
                return False

            if not object_id:
                print("FAILURE: missing id in upload response")
                return False

            download_url = (
                f"{node2_url}/api/object/"
                + urllib.parse.quote(object_id)
                + "?peer="
                + urllib.parse.quote(peer_id)
            )
            downloaded = b""
            status = 0
            t2 = 0.0
            t3 = 0.0
            for _ in range(30):
                t2 = time.perf_counter()
                status, downloaded, _ = get_bytes(download_url, timeout=120)
                t3 = time.perf_counter()
                if status == 200 and len(downloaded) == len(payload):
                    break
                time.sleep(0.2)
            if status != 200 or len(downloaded) != len(payload):
                print(
                    f"FAILURE: download status={status} size={len(downloaded)}"
                )
                return False

            upload_times.append(t1 - t0)
            download_times.append(t3 - t2)

            upload_mbps = format_mbps(len(payload), t1 - t0)
            download_mbps = format_mbps(len(payload), t3 - t2)
            print(
                f"Round {i}: upload={upload_mbps:.2f} MB/s "
                f"download={download_mbps:.2f} MB/s"
            )

        avg_upload = sum(upload_times) / len(upload_times)
        avg_download = sum(download_times) / len(download_times)
        print(
            f"Average: upload={format_mbps(payload_size, avg_upload):.2f} MB/s "
            f"download={format_mbps(payload_size, avg_download):.2f} MB/s"
        )
        return True
    finally:
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--size-mb", type=int, default=16)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--peer", type=str, default="oboard-mac")
    parser.add_argument("--node1-url", type=str, default="http://127.0.0.1:9000")
    parser.add_argument("--node2-url", type=str, default="http://127.0.0.1:9001")
    args = parser.parse_args()

    payload_size = max(1, args.size_mb) * 1024 * 1024
    ok = benchmark(
        payload_size,
        args.rounds,
        args.peer,
        args.node1_url,
        args.node2_url,
    )
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
