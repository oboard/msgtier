#!/bin/bash
set -e

if [ -d "msgtier-web" ]; then
  cd msgtier-web
  git pull
else
  git clone git@github.com:oboard/msgtier-web
  cd msgtier-web
fi

bun i
bun run build
cd dist
rm -rf ../../dist.zip
zip -r -9 ../../dist.zip *
