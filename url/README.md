# url

WHATWG URL Standard parser implementation in MoonBit. Parses and serializes URLs according to the [WHATWG URL Standard](https://url.spec.whatwg.org/) with web-platform-tests (WPT) compliance.

## Installation

```bash
moon add tonyfettes/url
```

## Usage

```moonbit
// Parse a URL
let url = @url.Url::parse("https://user:pass@example.com:8080/path?query=value#fragment")
match url {
  Some(url) => {
    println(url.protocol())   // "https:"
    println(url.hostname())   // "example.com"
    println(url.pathname())   // "/path"
    println(url.search())     // "?query=value"
    println(url.hash())       // "#fragment"
    println(url.to_string())  // full URL
  }
  None => println("Invalid URL")
}

// Parse relative URLs with a base
let base = @url.Url::parse("https://example.com/a/b/c").unwrap()
let relative = @url.Url::parse("../d", base~)
// Result: "https://example.com/a/d"

// Modify URL components
let url = @url.Url::parse("http://example.com/path").unwrap()
url.set_protocol("https:")
url.set_port("8080")
url.set_pathname("/new/path")
url.set_search("?foo=bar")
url.set_hash("#section")
```

## API

### Parsing

- `Url::parse(input: String, base?: Url) -> Url?` - Parse a URL string, optionally with a base URL for relative resolution

### Getters

| Method | Description |
|--------|-------------|
| `href()` | Full serialized URL |
| `protocol()` | Scheme with trailing colon (e.g., `"https:"`) |
| `get_username()` | Username component |
| `get_password()` | Password component |
| `get_host()` | Host with port (e.g., `"example.com:8080"`) |
| `hostname()` | Host without port |
| `get_port()` | Port as string (empty if default/none) |
| `pathname()` | Path component |
| `search()` | Query string with leading `?` |
| `hash()` | Fragment with leading `#` |
| `origin()` | Origin (scheme + host + port) |

### Setters

| Method | Description |
|--------|-------------|
| `set_protocol(protocol: String)` | Set scheme |
| `set_username(username: String)` | Set username |
| `set_password(password: String)` | Set password |
| `set_host(host: String)` | Set host (with optional port) |
| `set_hostname(hostname: String)` | Set hostname only |
| `set_port(port: String)` | Set port |
| `set_pathname(pathname: String)` | Set path |
| `set_search(search: String)` | Set query string |
| `set_hash(hash: String)` | Set fragment |

### Host Types

The parser recognizes four host types:

- `Domain(String)` - Domain names (with IDNA/Punycode support)
- `IPv4(IPv4)` - IPv4 addresses (supports decimal, octal, hex notation)
- `IPv6(IPv6)` - IPv6 addresses (supports `::` compression and IPv4-mapped)
- `Opaque(String)` - Opaque hosts for non-special schemes

## Features

- Full WHATWG URL Standard compliance
- 3700+ WPT test vectors passing
- Special scheme handling (http, https, ftp, file, ws, wss)
- Default port normalization
- Relative URL resolution
- Percent-encoding/decoding
- IPv4 and IPv6 address parsing
- IDNA/Punycode domain name support
- Windows drive letter handling for file URLs

## Build

```bash
moon check      # Type check and lint
moon build      # Build the project
moon test       # Run all tests
```

## License

Apache-2.0
