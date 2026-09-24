///|
/// Retain only IDs that can still participate in deduplication/debouncing.
/// Run independently of transport I/O so idle or unreachable peers cannot
/// prevent expired entries from being released.
fn prune_message_caches(now : UInt64) -> Unit {
  server_state.received_message_cache.retain((_, seen_at) => {
    now < seen_at || now - seen_at <= 30000UL
  })
  global_state.hello_times.retain((_, seen_at) => {
    now < seen_at || now - seen_at <= 5000UL
  })
  global_state.hello_callback_times.retain((_, expires_at) => now <= expires_at)
}

///|
fn start_message_cache_cleanup(root : @async.TaskGroup[Unit]) -> Unit {
  root.spawn_bg(() => {
    for ;; {
      @async.sleep(1000)
      prune_message_caches(@env.now())
    }
  })
}
