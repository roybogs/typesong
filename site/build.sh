#!/usr/bin/env bash
# Builds the public web version (GitHub Pages) from the shared engine page: _site/index.html plus its assets.
set -euo pipefail
cd "$(dirname "$0")/.."
URL="https://roybogs.github.io/typesong"
DESC="Turns your typing into music. Every key plays a note in key, the spacebar keeps the beat, and your speed sets the energy. Free and open source."
rm -rf _site && mkdir -p _site
cp site/og.jpg site/icon.png _site/
{
  cat <<HEAD
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="$DESC">
<meta property="og:type" content="website">
<meta property="og:url" content="$URL/">
<meta property="og:title" content="Typesong: turns your typing into music">
<meta property="og:description" content="$DESC">
<meta property="og:image" content="$URL/og.jpg">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="Typesong: turns your typing into music">
<meta name="twitter:description" content="$DESC">
<meta name="twitter:image" content="$URL/og.jpg">
<link rel="icon" href="icon.png">
<style>html,body{margin:0}.site-foot{max-width:880px;margin:8px auto 0;padding:0 16px 40px;font:14px/1.6 Figtree,system-ui,sans-serif;color:var(--muted)}.site-foot a{color:var(--accent);font-weight:600;text-decoration:none}.site-foot a:hover{text-decoration:underline}</style>
</head>
<body>
HEAD
  cat Engine/typesong.html
  cat <<'FOOT'
<p class="site-foot">Want it in every app, not just this box? Typesong lives in your menu bar on Mac, Windows and Linux:
<a href="https://github.com/roybogs/typesong">get it on GitHub</a>. Free and open source.</p>
</body>
</html>
FOOT
} > _site/index.html
echo "_site/index.html ready ($(wc -c < _site/index.html) bytes)"
