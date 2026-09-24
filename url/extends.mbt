// Trait methods for this package's types promoted to regular methods.
//
// The implicit promotion of `impl` methods is deprecated; these `pub extend`
// declarations keep the methods (`x.to_json()`, `x.to_repr()`, ...) callable
// as regular methods, as they were before.

///|
pub extend Host with @debug.Debug::{to_repr}

///|
pub extend Host with ToJson::{to_json}

///|
pub extend Host with @json.FromJson::{from_json}

///|
pub extend Host with Show::{output}

///|
pub extend ValidationError with ToJson::{to_json}

///|
pub extend IPv4 with @debug.Debug::{to_repr}

///|
pub extend IPv4 with Show::{output}

///|
pub extend IPv4 with ToJson::{to_json}

///|
pub extend IPv6 with @debug.Debug::{to_repr}

///|
pub extend IPv6 with Show::{output}

///|
pub extend IPv6 with ToJson::{to_json}

///|
pub extend Path with @debug.Debug::{to_repr}

///|
pub extend Url with @debug.Debug::{to_repr}

///|
pub extend Url with ToJson::{to_json}

///|
pub extend Url with @json.FromJson::{from_json}

///|
pub extend Url with Show::{output}
