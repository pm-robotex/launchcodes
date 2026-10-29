#!/usr/bin/env bash
# etag.sh <url> [body-file]
# Prints "<http status> <etag>" for <url> (a bare domain means its home page), following redirects (the last response
# counts), and saves what it got to <body-file> if one is given. The ETag is a fingerprint of what your host serves.
set -u
U="$1"; case "$U" in http*) ;; *) U="https://$U" ;; esac
case "${U#*://}" in */*) ;; *) U="$U/" ;; esac
CURL=(curl -sL -o "${2:-/dev/null}" -D - --max-time 30 --max-filesize 30000000)
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) curl --help all 2>/dev/null | grep -q -- '--ssl-revoke-best-effort' && CURL+=(--ssl-revoke-best-effort) ;;
esac
"${CURL[@]}" "$U" 2>/dev/null | tr -d '\r' \
  | awk '/^HTTP\// { st = $2; et = "" } tolower($0) ~ /^etag:/ { sub(/^[^:]*:[ \t]*/, ""); et = $0 } END { print (st ? st : "000") " " et }'
