#!/bin/bash
# Build the web console and refresh the archive the MoonBit side embeds.
#
# The MoonBit package `web/` embeds web/dist.zip at compile time and serves it
# from memory, so this must run before `moon build` when the UI changed.
set -euo pipefail

cd "$(dirname "$0")/web/msgtier-web"

pnpm install
pnpm exec vp build

cd dist
rm -f ../../dist.zip
zip -r -9 -q ../../dist.zip .
cd ../../

echo "wrote web/dist.zip ($(du -h dist.zip | cut -f1))"
