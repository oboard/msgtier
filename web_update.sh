#!/bin/bash
set -e

cd web/msgtier-web

pnpm i
pnpm run build
cd dist
rm -rf ../../dist.zip
zip -r -9 ../../dist.zip *

cd ../../