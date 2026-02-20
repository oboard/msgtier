#!/bin/bash
set -e

# Update submodule
git submodule update --init --recursive

cd msgtier-web
git pull origin main

bun i
bun run build
cd dist
rm -rf ../../dist.zip
zip -r -9 ../../dist.zip *
