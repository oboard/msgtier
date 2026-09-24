///|
/// A bounded, best-effort backlog. Successfully flushed lines are not retained.
priv struct BenchTraceBuffer {
  mut lines : Array[String]
  mut size_chars : Int
}

///|
fn BenchTraceBuffer::new() -> BenchTraceBuffer {
  { lines: [], size_chars: 0, }
}

///|
fn BenchTraceBuffer::push(self : BenchTraceBuffer, line : String) -> Unit {
  // Limit both item count and UTF-16 size, including unusually large details.
  // Drop new diagnostic lines under backpressure instead of growing forever.
  if self.lines.length() >= 1024 || line.length() > 128 * 1024 - self.size_chars {
    return
  }
  self.lines.push(line)
  self.size_chars += line.length()
}

///|
fn BenchTraceBuffer::take(self : BenchTraceBuffer) -> Array[String] {
  let lines = self.lines
  self.lines = []
  self.size_chars = 0
  lines
}

///|
let bench_trace_buffer : BenchTraceBuffer = BenchTraceBuffer::new()

///|
fn bench_trace_path() -> String {
  "/tmp/msgtier-bench-" + get_config().id + ".log"
}

///|
async fn reset_bench_trace() -> Unit {
  ignore(bench_trace_buffer.take())
  @fs.write_file(
    bench_trace_path(),
    b"",
    create_mode=@fs.CreateOrTruncate,
    permission=0o644,
  ) catch {
    _ => ()
  }
}

///|
async fn flush_bench_trace(buffer : BenchTraceBuffer, path : String) -> Unit {
  // Detach before yielding to I/O. Producers get a fresh bounded backlog even
  // while the filesystem is slow; failed writes do not retain batches either.
  let lines = buffer.take()
  if lines.is_empty() {
    return
  }
  @fs.write_file(
    path,
    @utf8.encode(lines.join("")),
    create_mode=@fs.OpenOrCreate,
    append=true,
    permission=0o644,
  ) catch {
    _ => ()
  }
}

///|
fn start_bench_trace_flusher(root : @async.TaskGroup[Unit]) -> Unit {
  root.spawn_bg(() => {
    for ;; {
      flush_bench_trace(bench_trace_buffer, bench_trace_path())
      @async.sleep(20)
    }
  })
}

///|
fn log_bench(stage : String, details? : String = "") -> Unit {
  let suffix = if details == "" { "" } else { " " + details }
  bench_trace_buffer.push("BENCH stage=\{stage} ts=\{@env.now()}\{suffix}\n")
}
