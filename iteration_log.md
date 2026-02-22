# 迭代记录

## 目标与问题
- 解决跨节点下载极慢与基准不稳定（连接不上、卡住、下载速度明显慢于上传）
- 提升 HTTP 代理消息投递可靠性与下载吞吐

## 迭代 1：稳定性与大包传输
- 调整响应分片大小：16MB -> 4MB，降低单次传输失败风险
  - 文件：[app_data_handler.mbt](file:///Users/oboard/Development/msgtier-projects/msgtier/cmd/main/app_data_handler.mbt#L1-L20)
- TCP 帧大小上限提升到 64MB，避免大响应被截断
  - 文件：[tcp_transport.mbt](file:///Users/oboard/Development/msgtier-projects/msgtier/cmd/main/tcp_transport.mbt#L1-L178)
- TCP 发送加自旋锁，避免并发写导致包交错
  - 文件：[tcp_transport.mbt](file:///Users/oboard/Development/msgtier-projects/msgtier/cmd/main/tcp_transport.mbt#L112-L130)

## 迭代 2：避免错误通道与错误地址
- http_proxy/response 优先走 TCP，避免被非 TCP 通道抢先发送导致不稳定
  - 文件：[server.mbt](file:///Users/oboard/Development/msgtier-projects/msgtier/cmd/main/server.mbt#L420-L468)
- 选地址时优先使用已知可连地址（监听地址/已知 peers），避免把请求发到临时端口
  - 文件：[global_utils.mbt](file:///Users/oboard/Development/msgtier-projects/msgtier/cmd/main/global_utils.mbt#L101-L155)

## Iteration 4: True Zero-Copy Streaming Implementation

**Issue:** Previous attempts at zero-copy streaming were incomplete (using placeholders or fallback to full file read), resulting in no speed improvement.
**Change:**
- Implemented `ResponseSource::FileStream` in `app_data_handler.mbt` using `@fs.open`, `@fs.size`, and `@fs.read_at`.
- Replaced `read_file` (load all) with chunked reading directly from file handle into `FixedArray` buffer.
- Handled partial reads and EOF correctly.
- Added logging to `http_service.mbt` to confirm zero-copy path usage.
- Optimized `tcp_transport.mbt` to write header and data separately (scatter-gather style) to avoid allocating a large buffer for packet concatenation, reducing memory copies.

**Files Modified:**
- `cmd/main/app_data_handler.mbt`: Implemented `FileStream` logic.
- `cmd/main/http_service.mbt`: Added logging.
- `cmd/main/tcp_transport.mbt`: Optimized `conn.write`.

**Expected Outcome:** significantly reduced memory usage and copies, potentially pushing throughput > 10MB/s.

## Iteration 3: Zero-Copy Preparation (Partial)
- 响应分片大小提升到 8MB，降低分片数量与协议开销
  - 文件：[app_data_handler.mbt](file:///Users/oboard/Development/msgtier-projects/msgtier/cmd/main/app_data_handler.mbt#L1-L20)
- 只在首个分片携带 status/headers，减少重复序列化开销
  - 文件：[app_data_handler.mbt](file:///Users/oboard/Development/msgtier-projects/msgtier/cmd/main/app_data_handler.mbt#L454-L608)

## 验证记录
- moon info && moon fmt
- moon check
- moon test

