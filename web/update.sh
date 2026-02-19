#!/bin/bash
set -e

if [ -d "msgtier-web" ]; then
  cd msgtier-web
  git pull
else
  git clone git@github.com:oboard/msgtier-web
  cd msgtier-web
fi

pnpm i
pnpm build

rm -rf ../dist.zip
zip -r ../dist.zip dist