# unicode

A MoonBit library implementing Unicode standards for text normalization and internationalized domain names.

## Features

- **Unicode Normalization (UAX #15)**: NFD, NFC, NFKD, NFKC normalization forms
- **Punycode (RFC 3492)**: Encoding/decoding for internationalized domain names
- **IDNA (UTS #46)**: Internationalized Domain Names in Applications processing

Targets Unicode 16.0.0.

## Installation

```bash
moon add oboard/msgtier/unicode
```

## Usage

### Unicode Normalization

```moonbit
// Normalize to NFC (Canonical Composition) - most common form
let nfc_text = @normalization.nfc("café")

// Normalize to NFD (Canonical Decomposition)
let nfd_text = @normalization.nfd("Å")  // A + combining ring above

// Normalize to NFKC (Compatibility Composition)
let nfkc_text = @normalization.nfkc("ﬁ")  // "fi"

// Normalize to NFKD (Compatibility Decomposition)
let nfkd_text = @normalization.nfkd("²")  // "2"

// Check if string is in a specific form
let is_nfc = @normalization.is_normalized("hello", @normalization.NFC)

// Generic normalize function
let text = @normalization.normalize("text", @normalization.NFKC)
```

### Punycode

```moonbit
// Encode Unicode to Punycode
let encoded = @punycode.encode("münchen")!  // "mnchen-3ya"
let encoded = @punycode.encode("中文")!      // "fiq228c"

// Decode Punycode to Unicode
let decoded = @punycode.decode("mnchen-3ya")!  // "münchen"
let decoded = @punycode.decode("fiq228c")!     // "中文"
```

### IDNA (Internationalized Domain Names)

```moonbit
// Convert domain to ASCII for DNS lookup
let ascii = @idna.to_ascii("münchen.de")!      // "xn--mnchen-3ya.de"
let ascii = @idna.to_ascii("中文.com")!         // "xn--fiq228c.com"
let ascii = @idna.to_ascii("ドメイン.jp")!       // "xn--eckwd4c7c.jp"

// Convert ASCII/Punycode domain to Unicode for display
let unicode = @idna.to_unicode("xn--mnchen-3ya.de")!  // "münchen.de"
let unicode = @idna.to_unicode("xn--fiq228c.com")!    // "中文.com"

// With validation options
let ascii = @idna.to_ascii(
  "example.com",
  use_std3_ascii_rules=true,
  check_hyphens=true,
  check_bidi=true,
  check_joiners=true,
  verify_dns_length=true,
)!
```

## API Reference

### @normalization

| Function | Description |
|----------|-------------|
| `nfc(s: String) -> String` | Normalize to NFC (Canonical Decomposition + Composition) |
| `nfd(s: String) -> String` | Normalize to NFD (Canonical Decomposition) |
| `nfkc(s: String) -> String` | Normalize to NFKC (Compatibility Decomposition + Composition) |
| `nfkd(s: String) -> String` | Normalize to NFKD (Compatibility Decomposition) |
| `normalize(s: String, form: NormalizationForm) -> String` | Normalize to specified form |
| `is_normalized(s: String, form: NormalizationForm) -> Bool` | Check if string is in specified form |

### @punycode

| Function | Description |
|----------|-------------|
| `encode(input: String) -> String raise PunycodeError` | Encode Unicode string to Punycode |
| `decode(input: String) -> String raise PunycodeError` | Decode Punycode string to Unicode |

### @idna

| Function | Description |
|----------|-------------|
| `to_ascii(domain: String, ...) -> String raise IdnaError` | Convert domain to ASCII (Punycode) |
| `to_unicode(domain: String, ...) -> String raise IdnaError` | Convert domain to Unicode |

**to_ascii / to_unicode options:**

- `use_std3_ascii_rules`: Apply STD3 ASCII rules (default: true)
- `check_hyphens`: Validate hyphen placement (default: true)
- `check_bidi`: Validate bidirectional text (default: true)
- `check_joiners`: Validate ZWNJ/ZWJ context (default: true)
- `verify_dns_length`: Check DNS length limits (default: true, to_ascii only)

## Building and Testing

```bash
moon check          # Type check the project
moon test           # Run all tests
moon test -p <pkg>  # Run tests for a specific package
moon fmt            # Format code
moon doc            # Generate documentation
```

## Standards Compliance

- [UAX #15: Unicode Normalization Forms](https://unicode.org/reports/tr15/)
- [RFC 3492: Punycode](https://datatracker.ietf.org/doc/html/rfc3492)
- [UTS #46: Unicode IDNA Compatibility Processing](https://unicode.org/reports/tr46/)
- [RFC 5891: IDNA Protocol](https://datatracker.ietf.org/doc/html/rfc5891)
- [RFC 5892: The Unicode Code Points and IDNA](https://datatracker.ietf.org/doc/html/rfc5892)
- [RFC 5893: Right-to-Left Scripts for IDNA](https://datatracker.ietf.org/doc/html/rfc5893)

## License

Apache-2.0
