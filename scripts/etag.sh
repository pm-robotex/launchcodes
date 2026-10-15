#!/usr/bin/env bash
# etag.sh <url>
# Prints "<http status> <etag>" for the home page of <url>, following redirects (the last response counts).
# The ETag is a fingerprint of the page your host serves: two deployments with the same home page share it.
set -u
U="${1%/}"; case "$U" in http*) ;; *) U="https://$U" ;; esac
CURL=(curl -sL -o /dev/null -D - --max-time 20)
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) curl --help all 2>/dev/null | grep -q -- '--ssl-revoke-best-effort' && CURL+=(--ssl-revoke-best-effort) ;;
esac
"${CURL[@]}" "$U/" 2>/dev/null | tr -d '\r' \
  | awk '/^HTTP\// { st = $2; et = "" } tolower($0) ~ /^etag:/ { sub(/^[^:]*:[ \t]*/, ""); et = $0 } END { print (st ? st : "000") " " et }'
