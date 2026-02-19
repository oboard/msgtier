#!/bin/bash
set -e

if [ -d "msgtier-web" ]; then
  cd msgtier-web
  git pull
else
  git clone https://github.com/oboard/msgtier-web.git
  cd msgtier-web
fi

pnpm i
pnpm build

rm -rf ../dist.zip
zip -r -9 ../dist.zip dist
