// Trait methods for this package's types promoted to regular methods.
//
// The implicit promotion of `impl` methods is deprecated; these `pub extend`
// declarations keep the methods (`x.to_json()`, `x.to_repr()`, ...) callable
// as regular methods, as they were before.

///|
pub extend Frame with @debug.Debug::{to_repr}

///|
pub extend Frame with Eq::{not_equal, equal}

///|
pub extend StreamFrame with @debug.Debug::{to_repr}

///|
pub extend StreamFrame with Eq::{not_equal, equal}

///|
pub extend AckFrame with @debug.Debug::{to_repr}

///|
pub extend AckFrame with Eq::{not_equal, equal}

///|
pub extend ResetStreamFrame with @debug.Debug::{to_repr}

///|
pub extend ResetStreamFrame with Eq::{not_equal, equal}

///|
pub extend StopSendingFrame with @debug.Debug::{to_repr}

///|
pub extend StopSendingFrame with Eq::{not_equal, equal}

///|
pub extend CryptoFrame with @debug.Debug::{to_repr}

///|
pub extend CryptoFrame with Eq::{not_equal, equal}

///|
pub extend NewTokenFrame with @debug.Debug::{to_repr}

///|
pub extend NewTokenFrame with Eq::{not_equal, equal}

///|
pub extend ConnectionCloseFrame with @debug.Debug::{to_repr}

///|
pub extend ConnectionCloseFrame with Eq::{not_equal, equal}

///|
pub extend PacketType with @debug.Debug::{to_repr}

///|
pub extend PacketType with Eq::{not_equal, equal}

///|
pub extend Header with @debug.Debug::{to_repr}

///|
pub extend Stream with @debug.Debug::{to_repr}
