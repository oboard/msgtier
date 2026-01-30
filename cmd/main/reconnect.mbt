///|
/// Reconnection manager with exponential backoff
struct ReconnectManager {
  retry_attempts : Map[String, Int] // peer_id -> attempt_count
  last_retry_time : Map[String, Int64] // peer_id -> timestamp
  base_delay_ms : Int
  max_delay_ms : Int
  max_attempts : Int
} derive(Show)

///|
fn ReconnectManager::new(
  base_delay_ms? : Int = 1000,
  max_delay_ms? : Int = 60000,
  max_attempts? : Int = 10,
) -> ReconnectManager {
  {
    retry_attempts: {},
    last_retry_time: {},
    base_delay_ms,
    max_delay_ms,
    max_attempts,
  }
}

///|
fn ReconnectManager::should_retry(
  self : ReconnectManager,
  peer_id : String,
) -> Bool {
  let current_time = 0L // TODO: get actual timestamp

  // Check if we've exceeded max attempts
  match self.retry_attempts.get(peer_id) {
    Some(attempts) =>
      if attempts >= self.max_attempts {
        false
      } else {
        // Check if enough time has passed since last retry
        match self.last_retry_time.get(peer_id) {
          Some(last_time) =>
            current_time - last_time >= self.get_next_delay(peer_id)
          None => true // First retry
        }
      }
    None => true // First retry
  }
}

///|
fn ReconnectManager::get_next_delay(
  self : ReconnectManager,
  peer_id : String,
) -> Int64 {
  let attempts = match self.retry_attempts.get(peer_id) {
    Some(count) => count
    None => 0
  }

  // Exponential backoff: base_delay * 2^attempts
  let delay = self.base_delay_ms * (1 << attempts.min(10)) // Cap at 2^10 = 1024x
  delay.min(self.max_delay_ms).to_int64()
}

///|
fn ReconnectManager::record_retry(
  self : ReconnectManager,
  peer_id : String,
) -> ReconnectManager {
  let retry_attempts = self.retry_attempts
  let last_retry_time = self.last_retry_time
  let current_time = 0L // TODO: get actual timestamp
  let attempts = match retry_attempts.get(peer_id) {
    Some(count) => count + 1
    None => 1
  }
  retry_attempts[peer_id] = attempts
  last_retry_time[peer_id] = current_time
  { ..self, retry_attempts, last_retry_time }
}

///|
fn ReconnectManager::reset_retry(
  self : ReconnectManager,
  peer_id : String,
) -> ReconnectManager {
  let retry_attempts = self.retry_attempts
  let last_retry_time = self.last_retry_time
  retry_attempts.remove(peer_id)
  last_retry_time.remove(peer_id)
  { ..self, retry_attempts, last_retry_time }
}

///|
fn ReconnectManager::get_retry_info(
  self : ReconnectManager,
  peer_id : String,
) -> (Int, Int64) {
  let attempts = match self.retry_attempts.get(peer_id) {
    Some(count) => count
    None => 0
  }
  let next_delay = self.get_next_delay(peer_id)
  (attempts, next_delay)
}
