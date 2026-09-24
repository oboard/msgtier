#!/usr/bin/env bash
set -euo pipefail

repo='oboard/msgtier'
install_dir="${INSTALL_DIR:-$HOME/.local/bin}"

case "$(uname -s):$(uname -m)" in
  Linux:x86_64|Linux:amd64) asset='msgtier-linux-x64' ;;
  Linux:aarch64|Linux:arm64) asset='msgtier-linux-arm64' ;;
  Darwin:arm64) asset='msgtier-macos-arm64' ;;
  *) echo "Unsupported platform: $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac

if ! command -v curl >/dev/null; then
  echo 'curl is required to install msgtier.' >&2
  exit 1
fi

if command -v sha256sum >/dev/null; then
  hash_command='sha256sum'
elif command -v shasum >/dev/null; then
  hash_command='shasum -a 256'
else
  echo 'sha256sum or shasum is required to verify the download.' >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
base_url="https://github.com/${repo}/releases/latest/download"
curl -fLsS --retry 3 "${base_url}/${asset}" -o "${tmp_dir}/${asset}"
curl -fLsS --retry 3 "${base_url}/SHA256SUMS" -o "${tmp_dir}/SHA256SUMS"
expected="$(awk -v name="$asset" '$2 == name { print $1 }' "$tmp_dir/SHA256SUMS")"
if [[ ! "$expected" =~ ^[a-fA-F0-9]{64}$ ]]; then
  echo "No valid SHA-256 checksum for ${asset}." >&2
  exit 1
fi
actual="$( $hash_command "$tmp_dir/$asset" | awk '{ print $1 }' )"
if [[ "$actual" != "$expected" ]]; then
  echo "Checksum mismatch for ${asset}." >&2
  exit 1
fi
mkdir -p "$install_dir"
install -m 0755 "$tmp_dir/$asset" "$install_dir/msgtier"
printf 'Installed msgtier to %s/msgtier\n' "$install_dir"
if [[ ":$PATH:" != *":$install_dir:"* ]]; then
  printf 'Add %s to PATH to run msgtier from any directory.\n' "$install_dir"
fi
