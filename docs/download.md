# Download and install

The installation scripts are served from this documentation site. They download the latest GitHub Release and verify the binary against its published SHA-256 checksum before installing it.

## Linux x64 / arm64 and macOS arm64

```bash
curl -fsSL https://msgtier.oboard.fun/install.sh | bash
```

The default destination is `~/.local/bin/msgtier`. Make sure `~/.local/bin` is on your `PATH`. To choose a different destination:

```bash
curl -fsSL https://msgtier.oboard.fun/install.sh | INSTALL_DIR="$HOME/bin" bash
```

You can inspect the [installation script](https://msgtier.oboard.fun/install.sh) before running it.

## Windows x64

Run in PowerShell:

```powershell
irm https://msgtier.oboard.fun/install.ps1 | iex
```

This installs to `%LOCALAPPDATA%\msgtier\bin\msgtier.exe` and adds the directory to your user `PATH`. Open a new PowerShell window after installation. Set `$env:INSTALL_DIR` first if you prefer another destination. You can inspect the [PowerShell script](https://msgtier.oboard.fun/install.ps1) before running it.

## Manual downloads

[GitHub Releases](https://github.com/oboard/msgtier/releases) provides `msgtier-linux-x64`, `msgtier-linux-arm64`, `msgtier-macos-arm64`, `msgtier-windows-x64.exe` and `SHA256SUMS`. macOS x64 is not available because the MoonBit CLI currently does not provide a macOS x64 toolchain.

## Build from source

See [Getting Started](/get-started#installation) for the native build steps. A checkout with the `web/msgtier-web` submodule, MoonBit, Node.js and pnpm are required.

After installation, create a [configuration file](/get-started#configuration), then start a node with:

```bash
msgtier node.json
```
