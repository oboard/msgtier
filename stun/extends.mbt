// Trait methods for this package's types promoted to regular methods.
//
// The implicit promotion of `impl` methods is deprecated; these `pub extend`
// declarations keep the methods (`x.to_json()`, `x.to_repr()`, ...) callable
// as regular methods, as they were before.

///|
pub extend StunError with @debug.Debug::{to_repr}

///|
pub extend MessageClass with @debug.Debug::{to_repr}

///|
pub extend MessageClass with Eq::{not_equal, equal}

///|
pub extend MappingBehavior with @debug.Debug::{to_repr}

///|
pub extend MappingBehavior with Eq::{not_equal, equal}

///|
pub extend FilteringBehavior with @debug.Debug::{to_repr}

///|
pub extend FilteringBehavior with Eq::{not_equal, equal}

///|
pub extend Attribute with @debug.Debug::{to_repr}

///|
pub extend Attribute with Eq::{not_equal, equal}

///|
pub extend Message with @debug.Debug::{to_repr}

///|
pub extend Message with Eq::{not_equal, equal}

///|
pub extend BindingProbeResult with @debug.Debug::{to_repr}

///|
pub extend BindingProbeResult with Eq::{not_equal, equal}

///|
pub extend NatProbeResult with @debug.Debug::{to_repr}

///|
pub extend NatProbeResult with Eq::{not_equal, equal}
