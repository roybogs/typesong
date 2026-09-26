#!/usr/bin/env bash
# Wraps the shared engine page (../Engine/typesong.html) in a document shell for the desktop app.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
{
  printf '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width, initial-scale=1">\n<style>html,body{margin:0}</style>\n</head>\n<body>\n'
  cat ../Engine/typesong.html
  printf '\n</body>\n</html>\n'
} > dist/index.html
echo "dist/index.html ready ($(wc -c < dist/index.html) bytes)"
