const http = require("http");
const crypto = require("crypto");

function parseIntArg(name, fallback) {
  const idx = process.argv.indexOf(name);
  if (idx === -1 || idx + 1 >= process.argv.length) {
    return fallback;
  }
  const value = Number.parseInt(process.argv[idx + 1], 10);
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

const port = parseIntArg("--port", 18110);
const totalMiB = parseIntArg("--size-mb", 16);
const chunkKiB = parseIntArg("--chunk-kb", 1024);
const totalBytes = totalMiB * 1024 * 1024;
const chunkBytes = chunkKiB * 1024;
const payload = Buffer.alloc(chunkBytes, 0x61);

function frameBuffer(data, opcode = 2) {
  const len = data.length;
  let header;
  if (len < 126) {
    header = Buffer.alloc(2);
    header[0] = 0x80 | opcode;
    header[1] = len;
  } else if (len <= 0xffff) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 126;
    header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
    header[1] = 127;
    header.writeUInt32BE(0, 2);
    header.writeUInt32BE(len, 6);
  }
  return Buffer.concat([header, data]);
}

function parseFrames(buffer, onFrame) {
  let offset = 0;
  while (offset + 2 <= buffer.length) {
    const b0 = buffer[offset];
    const b1 = buffer[offset + 1];
    const opcode = b0 & 0x0f;
    const masked = (b1 & 0x80) !== 0;
    let len = b1 & 0x7f;
    let headerLen = 2;
    if (len === 126) {
      if (offset + 4 > buffer.length) {
        break;
      }
      len = buffer.readUInt16BE(offset + 2);
      headerLen = 4;
    } else if (len === 127) {
      if (offset + 10 > buffer.length) {
        break;
      }
      const hi = buffer.readUInt32BE(offset + 2);
      const lo = buffer.readUInt32BE(offset + 6);
      len = hi * 2 ** 32 + lo;
      headerLen = 10;
    }
    const maskLen = masked ? 4 : 0;
    const frameLen = headerLen + maskLen + len;
    if (offset + frameLen > buffer.length) {
      break;
    }
    let payload = buffer.subarray(
      offset + headerLen + maskLen,
      offset + frameLen,
    );
    if (masked) {
      const mask = buffer.subarray(offset + headerLen, offset + headerLen + 4);
      const out = Buffer.alloc(len);
      for (let i = 0; i < len; i += 1) {
        out[i] = payload[i] ^ mask[i & 3];
      }
      payload = out;
    }
    onFrame(opcode, payload);
    offset += frameLen;
  }
  return buffer.subarray(offset);
}

function setupUpgrade(req, socket) {
  const accept = crypto
    .createHash("sha1")
    .update(
      req.headers["sec-websocket-key"] +
        "258EAFA5-E914-47DA-95CA-C5AB0DC85B11",
    )
    .digest("base64");
  socket.write(
    [
      "HTTP/1.1 101 Switching Protocols",
      "Upgrade: websocket",
      "Connection: Upgrade",
      `Sec-WebSocket-Accept: ${accept}`,
      "\r\n",
    ].join("\r\n"),
  );
}

const server = http.createServer();
server.on("upgrade", (req, socket) => {
  setupUpgrade(req, socket);

  if (req.url === "/download") {
    for (let sent = 0; sent < totalBytes; sent += chunkBytes) {
      const size = Math.min(chunkBytes, totalBytes - sent);
      const chunk = size === payload.length ? payload : payload.subarray(0, size);
      socket.write(frameBuffer(chunk));
    }
    socket.end();
    return;
  }

  if (req.url === "/upload") {
    let received = 0;
    let closed = false;
    let buffer = Buffer.alloc(0);
    socket.on("close", () => {
      closed = true;
    });
    socket.on("data", (chunk) => {
      if (closed) {
        return;
      }
      buffer = Buffer.concat([buffer, chunk]);
      buffer = parseFrames(buffer, (opcode, payloadChunk) => {
        if (opcode === 2) {
          received += payloadChunk.length;
        }
      });
      if (received >= totalBytes && !closed) {
        closed = true;
        socket.write(frameBuffer(Buffer.from("ok"), 1));
        socket.end();
      }
    });
    return;
  }

  socket.end();
});

function formatMiBPerSec(bytes, startMs) {
  const seconds = (performance.now() - startMs) / 1000;
  return bytes / 1024 / 1024 / seconds;
}

async function benchDownload() {
  return new Promise((resolve, reject) => {
    let received = 0;
    let started = 0;
    const ws = new WebSocket(`ws://127.0.0.1:${port}/download`);
    ws.binaryType = "arraybuffer";
    ws.onmessage = (event) => {
      if (started === 0) {
        started = performance.now();
      }
      received += event.data.byteLength;
      if (received >= totalBytes) {
        console.log(
          `node_ws_download=${formatMiBPerSec(received, started).toFixed(2)} MiB/s`,
        );
        ws.close();
        resolve();
      }
    };
    ws.onerror = reject;
  });
}

async function benchUpload() {
  return new Promise((resolve, reject) => {
    let started = 0;
    const ws = new WebSocket(`ws://127.0.0.1:${port}/upload`);
    ws.onopen = () => {
      started = performance.now();
      for (let sent = 0; sent < totalBytes; sent += chunkBytes) {
        const size = Math.min(chunkBytes, totalBytes - sent);
        const chunk = size === payload.length ? payload : payload.subarray(0, size);
        ws.send(chunk);
      }
    };
    ws.onmessage = () => {
      console.log(
        `node_ws_upload=${formatMiBPerSec(totalBytes, started).toFixed(2)} MiB/s`,
      );
      ws.close();
      resolve();
    };
    ws.onerror = reject;
  });
}

server.listen(port, "127.0.0.1", async () => {
  try {
    await benchDownload();
    await benchUpload();
  } catch (error) {
    console.error(error);
    process.exitCode = 1;
  } finally {
    server.close();
  }
});
