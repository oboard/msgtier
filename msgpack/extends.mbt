// Trait methods for this package's types promoted to regular methods.
//
// The implicit promotion of `impl` methods is deprecated; these `pub extend`
// declarations keep the methods (`x.to_json()`, `x.to_repr()`, ...) callable
// as regular methods, as they were before.

///|
pub extend Value with @debug.Debug::{to_repr}

///|
pub extend Value with Eq::{not_equal, equal}

///|
pub extend Value with ToJson::{to_json}

///|
pub extend MsgPackError with Show::{output}
