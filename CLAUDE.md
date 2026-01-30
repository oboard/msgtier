# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**MsgTier** is a decentralized P2P messaging network written in **MoonBit**. It provides:
- End-to-end encrypted messaging
- Decentralized architecture (no client/server distinction)
- Cross-platform support
- Event-driven architecture with relay capabilities
- A complete WHATWG-compliant URL parser library included as a subpackage

The project is organized as a multi-package MoonBit module with two main components:
1. **`cmd/main`** - The P2P network application
2. **`url`** - A standalone WHATWG URL standard library (3700+ WPT compliance)

## Development Workflow

### Setup

First-time setup requires configuring git hooks:
```bash
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit
```

The MoonBit compiler is required. For CI/CD setup, it's installed via:
```bash
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
```

### Common Development Commands

**Code Formatting & Validation:**
```bash
moon fmt                    # Format all code in the module
moon check                  # Lint/check code correctness
moon info                   # Regenerate package interface files (.mbti)
```

**Testing:**
```bash
moon test                   # Run all tests
moon test --update          # Update snapshot tests after behavior changes
moon coverage analyze       # Generate coverage report to see untested code
```

**Build & Development:**
```bash
moon update                 # Update module dependencies
moon version --all          # Show MoonBit version info
```

**Typical development flow:**
1. Make code changes
2. Run `moon check` (also runs automatically in pre-commit hook)
3. Run `moon test` to verify functionality
4. If snapshot tests fail due to intentional changes: `moon test --update`
5. Run `moon info && moon fmt` before committing (updates interfaces and formatting)

**Documentation:**
The `/docs` directory contains a VitePress-based documentation site. Install dependencies with `pnpm install` (in the docs directory), then build with VitePress.

## Architecture & Code Organization

### Block-Style Code Organization

MoonBit code in this project follows a **block-style convention**:
- Blocks are separated by `///|` comments
- Block order is irrelevant—each can be processed independently
- This convention enables incremental refactoring and processing
- Follow this pattern consistently when adding new functionality

### Module Structure

```
msgtier/
├── cmd/main/           # Main executable
│   ├── main.mbt        # Async task group entry point
│   ├── server.mbt      # UDP server implementation
│   ├── config.mbt      # Configuration parsing
│   └── moon.pkg.json   # Package manifest
├── url/                # WHATWG URL parser library
│   ├── url.mbt         # Core parsing (1,569 lines)
│   ├── host.mbt        # Host type (domain/IPv4/IPv6)
│   ├── ipv4.mbt        # IPv4 parsing
│   ├── ipv6.mbt        # IPv6 parsing with :: compression
│   ├── path.mbt        # URL path handling
│   ├── deprecated.mbt  # Deprecated code (if any)
│   ├── *_test.mbt      # Whitebox/public tests
│   ├── *_wbtest.mbt    # Blackbox tests
│   └── moon.pkg.json
├── moon.mod.json       # Module manifest
└── .mbti               # Generated package interfaces (auto-updated)
```

### Main Application Flow

The entry point in `cmd/main/main.mbt` uses MoonBit's async runtime:
1. Reads configuration from a JSON file (first CLI argument)
2. Parses configuration: node name, encryption secret, peer addresses, listener addresses
3. Spawns concurrent UDP server tasks for each configured listener using `@async.with_task_group()`
4. Each server task runs indefinitely, handling incoming UDP packets

**Key Type:** `Config` struct contains:
- `name: String` - Node identifier
- `secret: String` - Encryption secret
- `peers: Array[@url.Url]` - Peer node addresses
- `listeners: Array[@url.Url]` - Local bind addresses
- `scripts: Array[String]?` - Optional event scripts (not yet fully implemented)

### URL Parser Library Design

The `url/` package is a complete WHATWG URL Standard implementation:
- **url.mbt** - Main parsing/serialization engine with error handling
- **host.mbt** - Host type abstraction supporting domain names, IPv4, IPv6
- **ipv4.mbt** - IPv4 address parsing and validation
- **ipv6.mbt** - IPv6 parsing with :: compression normalization
- **path.mbt** - URL path component handling

**Key Features:**
- Custom `ValidationError` enum with 18 specific error types
- Support for special schemes (http, https, ftp, file, ws, wss)
- Default port normalization per scheme
- Percent-encoding/decoding for URL components
- IPv4 octal and hex notation parsing
- RFC-compliant IPv6 address handling
- Relative URL resolution with base URL support
- IDNA/Punycode domain name handling via unicode dependency

**Note:** The URL library is self-contained and can be used independently from the main messaging application.

## Key Dependencies

**Module-level** (`moon.mod.json`):
- `moonbitlang/async` (0.16.4) - Async runtime and task groups
- `tonyfettes/unicode` (0.3.0) - Unicode/IDNA support for domain parsing

**Main package** (`cmd/main/moon.pkg.json`):
- `moonbitlang/core/json` - JSON serialization
- `moonbitlang/core/env` - Environment variables
- `moonbitlang/async/socket` - UDP socket operations
- `moonbitlang/async/fs` - Async file I/O
- `oboard/msgtier/url` - Local URL parser package

**Build Target:**
- Prefers native compilation over WebAssembly (see `moon.mod.json` "preferred-target": "native")

## Testing Strategy

**Test File Naming:**
- `*_test.mbt` - Whitebox tests (public API testing)
- `*_wbtest.mbt` - Blackbox tests (internal implementation testing)

**Snapshot Testing:**
- Use `inspect()` function for snapshot-based testing
- Run `moon test --update` to regenerate snapshots when behavior intentionally changes
- Use explicit assertions (`assert_eq`) only within loops where snapshots may vary per iteration

**Coverage Analysis:**
- Use `moon coverage analyze > uncovered.log` to identify untested code
- Aim for comprehensive coverage, especially in parsing logic

## Code Generation & Interfaces

**Package Interface Files (.mbti):**
- Auto-generated by `moon info` command
- Documents the public API of each package
- Compare `.mbti` diffs to verify external API changes are intentional
- Always run `moon info` before committing to keep interfaces in sync

**Workflow:**
1. Make code changes
2. Run `moon test` to verify
3. Run `moon info` to update public interfaces
4. Review `.mbti` diffs
5. Run `moon fmt` to format
6. Commit with updated `.mbti` files

## Important Conventions

1. **Keep deprecated code organized** - Place deprecated functions/types in `deprecated.mbt` within each package
2. **Format before commit** - Pre-commit hook runs `moon check`, but `moon fmt` should be run explicitly
3. **Async operations** - Use MoonBit's async runtime (`@async.with_task_group()`) for concurrent networking operations
4. **Error handling** - Define specific error types (e.g., `ValidationError` with variant enum) rather than generic error handling
5. **String utilities** - Use `StringPointer` helper for character-by-character parsing in complex logic

## Preferred Target

The project is configured to compile to native binaries rather than WebAssembly, enabling better performance for network operations.
