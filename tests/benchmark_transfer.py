import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


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


def wait_http_ready(url, attempts=180, delay=0.2):
    for i in range(attempts):
        status, _, _ = get_bytes(url, timeout=2)
        if status == 200:
            return True
        if i % 10 == 0:
            log(f"waiting http ready: {url} attempt={i + 1}")
        time.sleep(delay)
    return False


def wait_peer_connected(status_url, peer_id, attempts=180, delay=0.5):
    for i in range(attempts):
        status, body, _ = get_bytes(status_url, timeout=2)
        if status == 200 and body:
            try:
                info = json.loads(body.decode("utf-8"))
                for peer in info.get("peers", []):
                    if peer.get("id") == peer_id and peer.get("connections"):
                        return True
            except Exception:
                pass
        if i % 10 == 0:
            log(f"waiting peer: {peer_id} status={status} attempt={i + 1}")
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


BENCH_RE = re.compile(r"BENCH stage=(\S+) ts=(\d+)(?: (.*))?$")
NODE1_TRACE = "/tmp/msgtier-bench-oboard-mac.log"
NODE2_TRACE = "/tmp/msgtier-bench-oboard-mac-2.log"


def parse_bench_markers(log_path):
    markers = []
    if not os.path.exists(log_path):
        return markers
    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            m = BENCH_RE.search(line)
            if not m:
                continue
            stage = m.group(1)
            ts = int(m.group(2))
            fields = {}
            raw_fields = m.group(3) or ""
            for part in raw_fields.split():
                if "=" not in part:
                    continue
                key, value = part.split("=", 1)
                fields[key] = value
            markers.append({"stage": stage, "ts": ts, "fields": fields})
    return markers


def find_latest_marker(markers, stage, **expected):
    for marker in reversed(markers):
        if marker["stage"] != stage:
            continue
        ok = True
        for key, value in expected.items():
            if marker["fields"].get(key) != value:
                ok = False
                break
        if ok:
            return marker
    return None


def analyze_round_stages(object_id, node1_log, node2_log):
    path = f"/api/object/{object_id}"
    node1_markers = parse_bench_markers(node1_log)
    node2_markers = parse_bench_markers(node2_log)
    start_marker = find_latest_marker(
        node2_markers, "proxy_stream_start", path=path
    )
    if not start_marker:
        return None
    req_id = start_marker["fields"].get("req")
    if not req_id:
        return None

    stages = {
        "node2_start": start_marker,
        "node1_recv": find_latest_marker(node1_markers, "http_proxy_recv", req=req_id),
        "node1_ready": find_latest_marker(
            node1_markers, "http_proxy_resp_ready", req=req_id
        ),
        "node1_send_start": find_latest_marker(
            node1_markers, "stream_send_start", req=req_id
        ),
        "node1_send_done": find_latest_marker(
            node1_markers, "stream_send_done", req=req_id
        ),
        "node2_first": find_latest_marker(
            node2_markers, "proxy_stream_first_chunk", req=req_id
        ),
        "node2_done": find_latest_marker(
            node2_markers, "proxy_stream_done", req=req_id
        ),
    }

    def diff_ms(a, b):
        if not a or not b:
            return None
        return b["ts"] - a["ts"]

    return {
        "req_id": req_id,
        "dispatch_ms": diff_ms(stages["node2_start"], stages["node1_recv"]),
        "prepare_ms": diff_ms(stages["node1_recv"], stages["node1_ready"]),
        "send_wait_ms": diff_ms(stages["node1_ready"], stages["node1_send_start"]),
        "first_byte_ms": diff_ms(stages["node1_send_start"], stages["node2_first"]),
        "send_total_ms": diff_ms(stages["node1_send_start"], stages["node1_send_done"]),
        "drain_ms": diff_ms(stages["node2_first"], stages["node2_done"]),
        "proxy_total_ms": diff_ms(stages["node2_start"], stages["node2_done"]),
    }


def format_stage_breakdown(stage_info):
    if not stage_info:
        return "stages=unavailable"
    ordered = [
        ("dispatch", stage_info.get("dispatch_ms")),
        ("prepare", stage_info.get("prepare_ms")),
        ("send_wait", stage_info.get("send_wait_ms")),
        ("first_byte", stage_info.get("first_byte_ms")),
        ("send_total", stage_info.get("send_total_ms")),
        ("drain", stage_info.get("drain_ms")),
        ("proxy_total", stage_info.get("proxy_total_ms")),
    ]
    parts = [f"req={stage_info['req_id']}"]
    for label, value in ordered:
        if value is not None:
            parts.append(f"{label}={value}ms")
    return " ".join(parts)


def benchmark(payload_size, rounds, peer_id, node1_url, node2_url, timeout=60):
    log("cleanup")
    cleanup()
    p1 = None
    p2 = None
    f1 = None
    f2 = None

    try:
        log("start node1")
        p1, f1 = run_node("config/1.jsonc", "tests/node1.log")
        log("wait node1 http ready")
        if not wait_http_ready(f"{node1_url}/api/config"):
            print("FAILURE: Node 1 HTTP not ready")
            return False

        log("start node2")
        p2, f2 = run_node("config/2.jsonc", "tests/node2.log")
        log("wait node2 http ready")
        if not wait_http_ready(f"{node2_url}/api/config"):
            print("FAILURE: Node 2 HTTP not ready")
            return False
        log("wait peer connected")
        if not wait_peer_connected(f"{node2_url}/api/status", peer_id):
            print(f"FAILURE: peer {peer_id} not connected on node2")
            return False

        payload = build_payload(payload_size)
        upload_url = f"{node1_url}/api/object"

        upload_times = []
        download_times = []

        for i in range(1, rounds + 1):
            log(f"round {i} upload start")
            t0 = time.perf_counter()
            status, body, _ = post_bytes(upload_url, payload, timeout=timeout)
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

            log(f"round {i} download start")
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
            for attempt in range(30):
                if attempt % 5 == 0:
                    log(f"round {i} download attempt {attempt + 1}")
                t2 = time.perf_counter()
                status, downloaded, _ = get_bytes(download_url, timeout=timeout)
                t3 = time.perf_counter()
                if status == 200 and len(downloaded) == len(payload):
                    break
                if attempt % 5 == 0:
                    log(
                        f"round {i} download retry status={status} size={len(downloaded)}"
                    )
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
            stage_info = analyze_round_stages(object_id, NODE1_TRACE, NODE2_TRACE)
            print(
                f"Round {i}: upload={upload_mbps:.2f} MB/s "
                f"download={download_mbps:.2f} MB/s "
                f"{format_stage_breakdown(stage_info)}"
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
    parser.add_argument("--timeout", type=int, default=60)
    args = parser.parse_args()

    payload_size = max(1, args.size_mb) * 1024 * 1024
    ok = benchmark(
        payload_size,
        args.rounds,
        args.peer,
        args.node1_url,
        args.node2_url,
        args.timeout,
    )
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
