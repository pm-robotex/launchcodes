#!/usr/bin/env bash
# setup.sh <repo> --domain <domain|none> [--supabase <project id|none>]
# setup.sh <repo> --ask-rule
# Only with the owner's yes. The first form, on a first run, creates .claude/launchcodes.json from the owner's own
# answers: the production branch (origin's default branch), the live domain (so the live check can say "Live"), and
# the PRODUCTION Supabase project (so the database check needs no question each release). It never overwrites an
# existing file: changing it later is the owner's job. Every value is checked before anything is written, and the
# file is checked again after.
# --ask-rule adds one rule to the owner's Claude Code user settings, "ask": ["Bash(*--owner-said-yes*)"], so the
# push asks them in every permission mode (gate.mjs explains why). It only ever adds that rule: everything else in
# the file stays as it is, and a file it can't read is left alone.
# Exit: 0 written (or already there) | 1 refused (file exists, or a value isn't valid) | 3 setup problem
set -u
S="$(cd "$(dirname "$0")" && pwd)"
R="$(git -C "${1:?usage: setup.sh <repo> --domain <domain|none> [--supabase <project id|none>]   or   setup.sh <repo> --ask-rule}" rev-parse --show-toplevel 2>/dev/null)" \
  || { echo "NOT A GIT REPO: $1"; exit 3; }
shift
DOMAIN=""; REF=""; ASK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="${2-}"; shift; [ $# -gt 0 ] && shift ;;
    --supabase) REF="${2-}"; shift; [ $# -gt 0 ] && shift ;;
    --ask-rule) ASK=1; shift ;;
    *) echo "unknown argument: $1"; exit 3 ;;
  esac
done
if [ $ASK = 1 ]; then
  node -e '
    const fs = require("fs"), path = require("path"), os = require("os");
    const RULE = "Bash(*--owner-said-yes*)";
    const dir = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), ".claude");
    const f = path.join(dir, "settings.json");
    let j = {};
    if (fs.existsSync(f)) {
      let t = fs.readFileSync(f, "utf8"); if (t.charCodeAt(0) === 0xfeff) t = t.slice(1);
      try { j = t.trim() ? JSON.parse(t) : {}; } catch (e) { console.log(`REFUSED: ${f} is not valid JSON (${e.message}), so it was left alone. Fix it, or add the rule by hand.`); process.exit(1); }
      if (!j || typeof j !== "object" || Array.isArray(j)) { console.log(`REFUSED: ${f} is not a JSON object, so it was left alone.`); process.exit(1); }
    }
    j.permissions = j.permissions && typeof j.permissions === "object" ? j.permissions : {};
    const ask = Array.isArray(j.permissions.ask) ? j.permissions.ask : [];
    if (ask.includes(RULE)) { console.log(`ALREADY THERE: ${f} already has the ask rule ${RULE}.`); process.exit(0); }
    j.permissions.ask = [...ask, RULE];
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(f, JSON.stringify(j, null, 2) + "\n");
    console.log(`ADDED to ${f}:  "permissions": { "ask": [ ..., "${RULE}" ] }`);' || exit $?
  node "$S/gate.mjs" "$R" "$S"; exit $?
fi
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
