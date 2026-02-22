#!/bin/bash
set -e

cd msgtier-web

bun i
bun run build
cd dist
rm -rf ../../dist.zip
zip -r -9 ../../dist.zip *
