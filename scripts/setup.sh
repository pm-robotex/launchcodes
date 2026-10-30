#!/usr/bin/env bash
# setup.sh <repo> --domain <domain|none> [--supabase <project id|none>]
# First run only. Creates .claude/launchcodes.json from the owner's own answers: the production branch (origin's
# default branch), the live domain (so the live check can say "Live"), and the PRODUCTION Supabase project (so the
# database check needs no question each release). Never overwrites an existing file: changing it later is the
# owner's job. Every value is checked before anything is written, and the file is checked again after.
# Exit: 0 written | 1 refused (file exists, or a value isn't valid) | 3 setup problem
set -u
S="$(cd "$(dirname "$0")" && pwd)"
R="$(git -C "${1:?usage: setup.sh <repo> --domain <domain|none> [--supabase <project id|none>]}" rev-parse --show-toplevel 2>/dev/null)" \
  || { echo "NOT A GIT REPO: $1"; exit 3; }
shift
DOMAIN=""; REF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="${2-}"; shift; [ $# -gt 0 ] && shift ;;
    --supabase) REF="${2-}"; shift; [ $# -gt 0 ] && shift ;;
    *) echo "unknown argument: $1"; exit 3 ;;
  esac
done
F="$R/.claude/launchcodes.json"
[ -e "$F" ] && { echo "REFUSED: $F already exists. Edit it yourself if a setting should change."; exit 1; }
[ "$DOMAIN" = none ] && DOMAIN=""
[ "$REF" = none ] && REF=""
DOMAIN="${DOMAIN%/}"
if [ -n "$DOMAIN" ] && ! printf '%s' "$DOMAIN" | LC_ALL=C grep -qE '^(https?://)?[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+(/[A-Za-z0-9._~/-]*)?$'; then
  echo "REFUSED: \"$DOMAIN\" doesn't look like a domain, like www.example.com. Nothing was written."; exit 1
fi
if [ -n "$REF" ] && ! printf '%s' "$REF" | LC_ALL=C grep -qE '^[a-z]{20}$'; then
  echo "REFUSED: \"$REF\" doesn't look like a Supabase project id: 20 lowercase letters, the part before .supabase.co"
  echo "in your project's URL. Nothing was written."; exit 1
fi
git -C "$R" fetch -q origin 2>/dev/null
PROD="$(git -C "$R" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
mkdir -p "$R/.claude" || exit 3
node -e '
  const [f, prod, domain, ref] = process.argv.slice(1);
  const cfg = {};
  if (prod) cfg.prodBranch = prod;
  if (domain) cfg.domain = domain;
  if (ref) cfg.supabaseProjectRef = ref;
  require("fs").writeFileSync(f, JSON.stringify(cfg, null, 2) + "\n");' "$F" "$PROD" "$DOMAIN" "$REF" || { echo "SETUP: couldn't write $F"; exit 3; }
msg="$(node "$S/cfg.mjs" "$R" --check)" || { rm -f "$F"; echo "REFUSED: $msg. Nothing was kept."; exit 1; }
echo "WROTE $F:"; cat "$F"
echo "Commit it, so everyone who releases this project uses the same settings (it holds no secrets)."
