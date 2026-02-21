import subprocess
import time
import urllib.request
import urllib.error
import urllib.parse
import json
import sys
import hashlib


def cleanup():
    print("Cleaning up existing processes...")
    subprocess.run(["pkill", "-f", "moon run cmd/main"], stderr=subprocess.DEVNULL)
    time.sleep(1)


def run_node(config_file, log_file):
    print(f"Starting node with {config_file}...")
    cmd = ["moon", "run", "cmd/main", "--debug", "--", config_file]
    f = open(log_file, "w", buffering=1)
    process = subprocess.Popen(cmd, stdout=f, stderr=subprocess.STDOUT, text=True)
    return process, f


def post_bytes(url, data, headers=None, timeout=10):
    req_headers = {"Content-Type": "application/octet-stream"}
    if headers:
        req_headers.update(headers)
    req = urllib.request.Request(url, data=data, headers=req_headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.getcode(), resp.read(), dict(resp.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers)
    except urllib.error.URLError:
        return 0, b"", {}
    except TimeoutError:
        return 0, b"", {}
    except OSError:
        return 0, b"", {}


def get_bytes(url, timeout=20):
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.getcode(), resp.read(), dict(resp.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers)
    except urllib.error.URLError:
        return 0, b"", {}
    except TimeoutError:
        return 0, b"", {}
    except OSError:
        return 0, b"", {}


def wait_http_ready(url, attempts=50, delay=0.2):
    for i in range(1, attempts + 1):
        status, _, _ = get_bytes(url, timeout=2)
        if status == 200:
            return True
        time.sleep(delay)
    return False


def test():
    cleanup()

    p1 = None
    p2 = None
    f1 = None
    f2 = None

    try:
        p1, f1 = run_node("config/1.jsonc", "tests/node1.log")
        print("Waiting for Node 1 HTTP to be ready...")
        if not wait_http_ready("http://127.0.0.1:9000/api/config"):
            print("FAILURE: Node 1 HTTP not ready")
            return False

        p2, f2 = run_node("config/2.jsonc", "tests/node2.log")
        print("Waiting for Node 2 HTTP to be ready...")
        if not wait_http_ready("http://127.0.0.1:9001/api/config"):
            print("FAILURE: Node 2 HTTP not ready")
            return False

        payload = (b"msgtier-file-transfer\n" * 16384) + bytes(range(256))
        payload_sha = hashlib.sha256(payload).hexdigest()
        print(f"Payload size={len(payload)} sha256={payload_sha}")

        upload_url = "http://127.0.0.1:9000/api/object"
        print(f"Uploading to {upload_url}...")
        status, body, _ = post_bytes(upload_url, payload, timeout=10)
        if status != 200:
            print(f"FAILURE: upload status={status} body={body!r}")
            return False

        try:
            obj = json.loads(body.decode("utf-8"))
            object_id = obj.get("id", "")
        except Exception as e:
            print(f"FAILURE: cannot parse upload response: {e} body={body!r}")
            return False

        if not object_id:
            print(f"FAILURE: missing id in upload response body={body!r}")
            return False

        filename = "integration.bin"
        download_url = (
            "http://127.0.0.1:9001/api/object/"
            + urllib.parse.quote(object_id)
            + "?peer="
            + urllib.parse.quote("oboard-mac")
            + "&filename="
            + urllib.parse.quote(filename)
        )

        downloaded = b""
        headers = {}
        status = 0
        for attempt in range(1, 6):
            print(f"Downloading from {download_url}... attempt={attempt}")
            status, downloaded, headers = get_bytes(download_url, timeout=30)
            if status == 200:
                break
            if status in (504, 404):
                time.sleep(1)
                continue
            print(f"FAILURE: download status={status} body_len={len(downloaded)}")
            return False

        if status != 200:
            print(f"FAILURE: download status={status} body_len={len(downloaded)}")
            return False

        downloaded_sha = hashlib.sha256(downloaded).hexdigest()
        print(f"Downloaded size={len(downloaded)} sha256={downloaded_sha}")

        if downloaded != payload:
            print("FAILURE: downloaded bytes mismatch")
            return False

        cd = headers.get("Content-Disposition", "")
        if filename not in cd:
            print(f"FAILURE: missing/invalid Content-Disposition: {cd!r}")
            return False

        print("SUCCESS: file transfer end-to-end is valid.")
        return True

    finally:
        print("Stopping nodes...")
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
    if test():
        sys.exit(0)
    else:
        sys.exit(1)
