// Trait methods for this package's types promoted to regular methods.
//
// The implicit promotion of `impl` methods is deprecated; these `pub extend`
// declarations keep the methods (`x.to_json()`, `x.to_repr()`, ...) callable
// as regular methods, as they were before.

///|
pub extend NanoidError with @debug.Debug::{to_repr}

///|
pub extend NanoidError with Eq::{not_equal, equal}
