#!/usr/bin/env bash
# plan.sh <WT> --name '<release name>' [--db checked|not-checked]
# plan.sh <WT> --status
# Step 4. Records this release's name and the exact list of files you're about to approve (push.sh refuses if it
# changes), and prints the facts the plain-language plan is built from. --status shows where a release is, for
# example after a long pause or a compacted conversation.
# The name may use only letters, digits, spaces and , . : + / & ( ) - so it can never be read as a command.
# Exit: 0 ready to ask (or status shown) | 1 not ready | 3 setup
set -u
WT="${1:?usage: plan.sh <WT> --name '<name>' [--db checked|not-checked]   or   plan.sh <WT> --status}"; shift
[ -f "$WT/.launch-state" ] || { echo "NO STATE in $WT: run prepare.sh first"; exit 3; }
. "$WT/.launch-state"
NAME=""; DBR=""; MODE=plan
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2-}"; shift; [ $# -gt 0 ] && shift ;;
    --name=*) NAME="${1#--name=}"; shift ;;
    --db) DBR="${2-}"; shift; [ $# -gt 0 ] && shift ;;
    --db=*) DBR="${1#--db=}"; shift ;;
    --status) MODE=status; shift ;;
    *) echo "unknown argument: $1"; exit 3 ;;
  esac
done
LINT_V="${LINT:-}"; LINT_W="${LINT_V%% *}"; LINT_T="${LINT_V##* }"
checked=no; [ "${PATHS_OK:-}" = "$TREE" ] && [ "${SECRETS_OK:-}" = "$TREE" ] && [ "$LINT_T" = "$TREE" ] && checked=yes
dry=""; [ "$DRY_RUN" = 1 ] && dry="   (DRY RUN: nothing will be pushed)"

if [ $MODE = status ]; then
  echo "Ship $CODE · ${SHIP_NAME:-(not named yet)}"
  echo "  $PROD on origin: ${BASE:0:7} -> ${T:0:7}$dry"
  b=no; [ "${BUILT_TREE:-}" = "$TREE" ] && b=yes; p=no; [ "${PLANNED:-}" = "$TREE" ] && p=yes
  echo "  built: $b · checked: $checked · planned: $p"
  if [ -n "${PUSHED:-}" ]; then echo "  PUSHED: $PUSHED. Never push again; go to the live check."; else echo "  pushed: no"; fi
  exit 0
fi

[ "${BUILT_TREE:-}" = "$TREE" ] || { echo "NOT BUILT: run build.sh first"; exit 1; }
[ $checked = yes ] || { echo "NOT CHECKED: run check.sh first (it must print CHECKS_PASSED)"; exit 1; }
if [ "${DB:-none}" = sql-ready ]; then
  case "$DBR" in checked|not-checked) ;; *)
    echo "DATABASE QUERY NOT RUN YET: run the query check.sh printed on PRODUCTION, then pass --db checked (it returned"
    echo "zero rows) or --db not-checked (the owner chose to skip it)."; exit 1 ;;
  esac
else DBR=none; fi
[ -n "$NAME" ] || { echo "NO NAME: pass --name '<2 to 6 words saying what this release does>'"; exit 1; }
if ! printf '%s' "$NAME" | LC_ALL=C grep -qE '^[A-Za-z0-9][A-Za-z0-9 ,.:+/&()-]{1,59}$'; then
  echo "BAD NAME: 2 to 60 characters, using only letters, digits, spaces and , . : + / & ( ) - (no quotes or apostrophes:"
  echo "write 'do not', not 'don't'; and write code names plainly, like useAuth)"; exit 1
fi

grep -v -E '^(SHIP_NAME|DB_RESULT|PLANNED)=' "$WT/.launch-state" > "$WT/.launch-tmp" && mv "$WT/.launch-tmp" "$WT/.launch-state"
git -c core.quotePath=false -C "$R" diff --name-only --no-renames "$BASE" "$T" > "$WT/.launch-approved-files" || { echo "SETUP: git diff failed"; exit 3; }
{ printf 'SHIP_NAME=%q\n' "$NAME"; printf 'DB_RESULT=%q\n' "$DBR"; printf 'PLANNED=%q\n' "$TREE"; } >> "$WT/.launch-state"
printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M %Z')" "$CODE" PLANNED "$NAME" >> "$LOG" 2>/dev/null

echo "PLAN FACTS: Ship $CODE · $NAME"
echo "  release: $(git -C "$R" rev-list --count "$BASE..$T") commit(s) to $PROD on origin, ${BASE:0:7} -> ${T:0:7}$dry"
echo "  commits (oldest first), each with the files it changes (A added, M changed, D deleted):"
git -C "$R" log --reverse --format='%h%x09%p%x09%s' "$BASE..$T" | while IFS=$'\t' read -r h p s; do
  flag=""
  if printf '%s' "$s" | grep -qiE '(^|[^a-z])(wip|tmp|temp|debug|hack|fixme|xxx|do not (ship|merge|push|deploy)|don.?t (ship|merge|push|deploy)|local only|test only)([^a-z]|$)|^(fixup|squash)!'; then
    flag="   <- SUSPECT: looks like unfinished or local-only work"
  fi
  echo "    $h  $s$flag"
  # A merge is listed against its first parent: what it brings into the branch.
  case "$p" in
    *" "*) git -c core.quotePath=false -C "$R" diff --name-status --no-renames "$h^1" "$h" ;;
    *) git -c core.quotePath=false -C "$R" diff-tree -r --root --no-commit-id --name-status --no-renames "$h" ;;
  esac > "$WT/.launch-files-tmp" 2>/dev/null
  n=$(grep -c . "$WT/.launch-files-tmp")
  head -8 "$WT/.launch-files-tmp" | sed 's/^/        /'
  [ "$n" -gt 8 ] && echo "        (+$((n - 8)) more)"
done
rm -f "$WT/.launch-files-tmp"
echo "  files: $(git -C "$R" diff --shortstat --no-renames "$BASE" "$T" | sed 's/^ *//')"
added="$(git -c core.quotePath=false -C "$R" diff --name-only --diff-filter=A --no-renames "$BASE" "$T" | grep -iE '(^|/)(seeds?|fixtures?|mocks?)(/|\.)' | head -5)"
[ -n "$added" ] && { echo "  SUSPECT files (test data going live?):"; echo "$added" | sed 's/^/    /'; }
head="$(git -C "$R" rev-parse HEAD)"
if [ "$head" != "$T" ] && git -C "$R" merge-base --is-ancestor "$T" "$head" 2>/dev/null; then
  echo "  NEWER: $(git -C "$R" rev-list --count "$T..$head") commit(s) on your branch are NOT in this release"
fi
unc=$(git -C "$R" status --porcelain | grep -c .)
[ "$unc" -gt 0 ] && echo "  UNCOMMITTED: $unc file(s) in your folder aren't committed, so they are NOT in this release"
case "${BUILD_STATUS:-}" in passed) b="build ✓" ;; *) b="nothing to build" ;; esac
case "$LINT_W" in passed) l="code check ✓" ;; skipped) l="code check skipped (ESLint missing or too old)" ;; none) l="code check: no JS files changed" ;; *) l="code check switched off" ;; esac
case "$DBR" in checked) d="database ✓" ;; not-checked) d="database NOT checked (the owner chose to skip it)" ;; *) d="database: nothing to check" ;; esac
envs=""; [ "${BUILD_ENV:-0}" != 0 ] && envs=" · the build used $BUILD_ENV env file(s) from your folder"
echo "  checks: $b · secret files ✓ · keys in code ✓ · $l · $d$envs"
echo "  the build ran: ${BUILD_CMDS:-?}"
echo "  live check: $LIVE_CHECK"
echo "  approval: only the owner's yes to this plan, then  push.sh <WT> --owner-said-yes=$CODE"
echo "READY_TO_ASK"
