// Trait methods for this package's types promoted to regular methods.
//
// The implicit promotion of `impl` methods is deprecated; these `pub extend`
// declarations keep the methods (`x.to_json()`, `x.to_repr()`, ...) callable
// as regular methods, as they were before.

///|
pub extend Message with @morm/engine.FromParam::{from_param}

///|
pub extend Message with ToJson::{to_json}

///|
pub extend Message with @json.FromJson::{from_json}

///|
pub extend MessageMapperImpl with MessageMapper::{save}
