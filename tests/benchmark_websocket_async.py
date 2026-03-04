import argparse
import asyncio
import base64
import hashlib
import os
import subprocess
import sys
import time


GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
DEFAULT_PORT = 18110


def log(msg):
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def make_frame(data: bytes, opcode: int = 2, masked: bool = False) -> bytes:
    first = 0x80 | opcode
    n = len(data)
    if n < 126:
        header = bytearray([first, (0x80 if masked else 0) | n])
    elif n <= 0xFFFF:
        header = bytearray([first, (0x80 if masked else 0) | 126])
        header += n.to_bytes(2, "big")
    else:
        header = bytearray([first, (0x80 if masked else 0) | 127])
        header += n.to_bytes(8, "big")
    if not masked:
        return bytes(header) + data
    mask = os.urandom(4)
    masked_data = bytearray(n)
    for i, b in enumerate(data):
        masked_data[i] = b ^ mask[i & 3]
    return bytes(header) + mask + bytes(masked_data)


async def read_frame(reader: asyncio.StreamReader):
    hdr = await reader.readexactly(2)
    b0, b1 = hdr
    opcode = b0 & 0x0F
    masked = (b1 & 0x80) != 0
    length = b1 & 0x7F
    if length == 126:
        length = int.from_bytes(await reader.readexactly(2), "big")
    elif length == 127:
        length = int.from_bytes(await reader.readexactly(8), "big")
    mask = await reader.readexactly(4) if masked else None
    data = bytearray(await reader.readexactly(length))
    if masked:
        for i in range(length):
            data[i] ^= mask[i & 3]
    return opcode, bytes(data)


async def handle_ws(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    total_bytes: int,
    chunk_bytes: int,
):
    payload = b"a" * chunk_bytes
    req = await reader.readuntil(b"\r\n\r\n")
    text = req.decode("utf-8", "replace")
    lines = text.split("\r\n")
    path = lines[0].split(" ")[1]
    headers = {}
    for line in lines[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    key = headers["sec-websocket-key"]
    accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    resp = (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
    )
    writer.write(resp.encode())
    await writer.drain()

    if path == "/download":
        for sent in range(0, total_bytes, chunk_bytes):
            size = min(chunk_bytes, total_bytes - sent)
            chunk = payload if size == len(payload) else payload[:size]
            writer.write(make_frame(chunk))
            if (sent // chunk_bytes) % 4 == 3:
                await writer.drain()
        await writer.drain()
        writer.close()
        await writer.wait_closed()
        return

    if path == "/upload":
        got = 0
        while got < total_bytes:
            opcode, data = await read_frame(reader)
            if opcode == 2:
                got += len(data)
        writer.write(make_frame(b"ok", opcode=1))
        await writer.drain()
        writer.close()
        await writer.wait_closed()
        return

    writer.close()
    await writer.wait_closed()


async def ws_connect(port: int, path: str):
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    key = base64.b64encode(os.urandom(16)).decode()
    req = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: 127.0.0.1:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    writer.write(req.encode())
    await writer.drain()
    await reader.readuntil(b"\r\n\r\n")
    return reader, writer


async def bench_python(size_mb: int, chunk_kb: int, port: int):
    total_bytes = size_mb * 1024 * 1024
    chunk_bytes = chunk_kb * 1024

    server = await asyncio.start_server(
        lambda r, w: handle_ws(r, w, total_bytes, chunk_bytes),
        "127.0.0.1",
        port,
    )
    async with server:
        reader, writer = await ws_connect(port, "/download")
        got = 0
        start = time.perf_counter()
        while got < total_bytes:
            opcode, data = await read_frame(reader)
            if opcode == 2:
                got += len(data)
        seconds = time.perf_counter() - start
        print(f"python_ws_download={total_bytes / 1024 / 1024 / seconds:.2f} MiB/s")
        writer.close()
        await writer.wait_closed()

        reader, writer = await ws_connect(port, "/upload")
        payload = b"a" * chunk_bytes
        start = time.perf_counter()
        for sent in range(0, total_bytes, chunk_bytes):
            size = min(chunk_bytes, total_bytes - sent)
            chunk = payload if size == len(payload) else payload[:size]
            writer.write(make_frame(chunk, masked=True))
            if (sent // chunk_bytes) % 4 == 3:
                await writer.drain()
        await writer.drain()
        await read_frame(reader)
        seconds = time.perf_counter() - start
        print(f"python_ws_upload={total_bytes / 1024 / 1024 / seconds:.2f} MiB/s")
        writer.close()
        await writer.wait_closed()


def bench_node(size_mb: int, chunk_kb: int, port: int):
    cmd = [
        "node",
        "tests/benchmark_websocket_async_node.js",
        "--size-mb",
        str(size_mb),
        "--chunk-kb",
        str(chunk_kb),
        "--port",
        str(port),
    ]
    result = subprocess.run(cmd, check=False, text=True)
    if result.returncode != 0:
        raise SystemExit(result.returncode)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--size-mb", type=int, default=16)
    parser.add_argument("--chunk-kb", type=int, default=1024)
    parser.add_argument(
        "--runtime",
        choices=["node", "python", "both"],
        default="both",
    )
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    args = parser.parse_args()

    size_mb = max(1, args.size_mb)
    chunk_kb = max(1, args.chunk_kb)

    if args.runtime in ("node", "both"):
        log("benchmark node websocket async")
        bench_node(size_mb, chunk_kb, args.port)
    if args.runtime in ("python", "both"):
        py_port = args.port if args.runtime == "python" else args.port + 1
        log("benchmark python websocket async")
        asyncio.run(bench_python(size_mb, chunk_kb, py_port))


if __name__ == "__main__":
    main()
