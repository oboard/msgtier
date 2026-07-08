#!/bin/bash
set -e

cd msgtier-web

pnpm i
pnpm run build
cd dist
rm -rf ../../dist.zip
zip -r -9 ../../dist.zip *
