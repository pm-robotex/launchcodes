#!/usr/bin/env bash
# check.sh <WT>
# Step 3. Runs every check on the commit that would go live, and records each result against that commit's exact
# tree, so push.sh can refuse a commit that wasn't checked:
#   secret files   never_ships.mjs   every commit in the release, not just the end result
#   secret text    secret_scan.mjs   keys pasted into files, in every commit
#   code check     scope_lint.mjs    names used but never defined (they build fine and crash in the browser)
#   database       db_refs.mjs + refcheck_sql.mjs   Supabase only: prints ONE read-only query to run on PRODUCTION
# Exit: 0 CHECKS_PASSED (then run the printed query, if any) | 1 CHECKS_BLOCKED | 2 a check couldn't run | 3 setup
set -u
WT="${1:?usage: check.sh <WT>}"
[ -f "$WT/.launch-state" ] || { echo "NO STATE in $WT: run prepare.sh first"; exit 3; }
. "$WT/.launch-state"
grep -v -E '^(PATHS_OK|SECRETS_OK|LINT|DB|SHIP_NAME|DB_RESULT|PLANNED)=' "$WT/.launch-state" > "$WT/.launch-tmp" && mv "$WT/.launch-tmp" "$WT/.launch-state"
[ "${BUILT_TREE:-}" = "$TREE" ] || { echo "NOT BUILT: run build.sh first (it must print BUILD_PASSED or BUILD_SKIPPED)"; exit 3; }
rec() { printf '%s=%q\n' "$1" "$2" >> "$WT/.launch-state"; }
blocked=0; broken=0

echo "== Secret files (every commit in this release)"
node "$S/never_ships.mjs" "$R" "$BASE" "$T" "$PROD"; rc=$?
case $rc in 0) rec PATHS_OK "$TREE" ;; 1) blocked=1 ;; *) broken=1 ;; esac

echo; echo "== Keys pasted into files (every commit in this release)"
node "$S/secret_scan.mjs" "$R" "$BASE" "$T" "$PROD"; rc=$?
case $rc in 0) rec SECRETS_OK "$TREE" ;; 1) blocked=1 ;; *) broken=1 ;; esac

echo; echo "== Code check (names used but never defined)"
cc="$(node "$S/cfg.mjs" "$R" codeCheck "true")" || { echo "$cc"; exit 3; }
APPDIR="$(node "$S/cfg.mjs" "$R" appDir "")" || { echo "$APPDIR"; exit 3; }
if [ "$cc" = false ]; then
  echo "switched off (\"codeCheck\": false in .claude/launchcodes.json)"; rec LINT "off $TREE"
else
  node "$S/scope_lint.mjs" "$R" "$BASE" "$T" "$WT${APPDIR:+/$APPDIR}"; rc=$?
  case $rc in 0) rec LINT "passed $TREE" ;; 1) blocked=1 ;; 3) rec LINT "skipped $TREE" ;; 4) rec LINT "none $TREE" ;; *) broken=1 ;; esac
fi

echo; echo "== Production database (Supabase)"
node "$S/db_refs.mjs" "$R" "$BASE" "$T" --out "$WT/.launch-refs.json"; rc=$?
if [ $rc -eq 3 ]; then rec DB none
elif [ $rc -ne 0 ]; then broken=1
elif node "$S/refcheck_sql.mjs" "$WT/.launch-refs.json" > "$WT/.launch-refcheck.sql"; then
  rec DB sql-ready
  echo "Run this ONE read-only query on your PRODUCTION Supabase project. Zero rows = pass:"
  echo "-----BEGIN LAUNCHCODES SQL-----"; cat "$WT/.launch-refcheck.sql"; echo "-----END LAUNCHCODES SQL-----"
else broken=1; fi

echo
if [ $broken = 1 ]; then echo "CHECKS DID NOT ALL RUN: never read that as a pass."; exit 2; fi
if [ $blocked = 1 ]; then echo "CHECKS_BLOCKED: fix what's listed above, commit, and run /launchcodes again."; exit 1; fi
echo "CHECKS_PASSED"
echo "NEXT: plan"
