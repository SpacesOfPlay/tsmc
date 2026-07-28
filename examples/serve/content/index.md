---
title: tsmc example server
tags:
  - demo
  - tsmc
---

# tsmc content server

This page is Markdown, rendered by [markdown-it](https://github.com/markdown-it/markdown-it)
and served over TLS 1.3 — all of it running on `tsmc`.

The front-matter above is parsed with **js-yaml**. Both are ordinary npm
packages resolved out of `node_modules`.

## What this exercises

- TypeScript executed directly, no build step
- `node_modules` resolution for real packages
- an HTTPS server whose TLS is terminated by tsmc itself
- `fs`, `path`, `crypto` (SHA-256 entity tags), `zlib` (gzip)

Try: `/notes/`, `/notes/regex.md`, and `/style.css`.

Bare URLs get linkified too: https://minc.dev
