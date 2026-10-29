#!/usr/bin/env bash
# push.sh <WT> --owner-said-yes=<launch code>
# Step 5, the only step that changes production.
# push.sh can't hear you. It refuses unless Claude passes --owner-said-yes=<this release's launch code>, which the
# skill allows only after you answered yes to the plan. The hard stop is Claude Code's permission prompt for this
# command: launchcodes pre-approves its other steps, never this one.
# Refuses ("NOT PUSHED", exit 1) unless ALL of these hold right now:
#   1. the code matches this release, and this isn't a dry run
#   2. this exact commit was built, checked (secret files, keys in code, code check) and planned
#   3. production on origin is still exactly where it was when this started (nobody pushed or rolled it back)
#   4. the files changing are exactly the list you approved
#   5. both secret checks still pass (run again here, the last moment before the push)
# Then it pushes that exact commit by its id (never a branch name, never --force) and checks GitHub has it. With
# "releaseCommit" it pushes a merge commit named "Ship <code> · <name>" on top instead, holding the same files.
set -u
WT="${1:?usage: push.sh <WT> --owner-said-yes=<launch code>}"
[ -f "$WT/.launch-state" ] || { echo "NOT PUSHED: no state in $WT"; exit 1; }
. "$WT/.launch-state"
said=""; case "${2:-}" in --owner-said-yes=*) said="${2#--owner-said-yes=}" ;; esac
[ -n "$said" ] && [ "$said" = "$CODE" ] || { echo "NOT PUSHED: needs --owner-said-yes=$CODE, passed only after the owner answered yes to this plan"; exit 1; }
[ "$DRY_RUN" = 1 ] && { echo "NOT PUSHED: this is a dry run"; exit 1; }
[ -n "${PUSHED:-}" ] && { echo "ALREADY_PUSHED: $PUSHED. Go to the live check."; exit 0; }
[ "$(git -C "$R" rev-parse "$T^{tree}" 2>/dev/null)" = "$TREE" ] || { echo "NOT PUSHED: the state file doesn't match the commit"; exit 1; }
[ "${BUILT_TREE:-}" = "$TREE" ] || { echo "NOT PUSHED: NOT_BUILT (run build.sh)"; exit 1; }
LINT_V="${LINT:-}"
[ "${PATHS_OK:-}" = "$TREE" ] && [ "${SECRETS_OK:-}" = "$TREE" ] && [ "${LINT_V##* }" = "$TREE" ] || { echo "NOT PUSHED: NOT_CHECKED (run check.sh)"; exit 1; }
[ "${PLANNED:-}" = "$TREE" ] && [ -f "$WT/.launch-approved-files" ] || { echo "NOT PUSHED: no plan recorded (run plan.sh and show the plan first)"; exit 1; }

led() { printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M %Z')" "$CODE" "$1" "$2" >> "$LOG" 2>/dev/null; }
TIP="$T"    # what lands on top of $PROD: the release's commit, or (with "releaseCommit") a merge commit named after it
pushed() {
  stamp="$(date '+%Y-%m-%d %H:%M %Z')"
  printf 'PUSHED=%q\n' "$TIP at $stamp" >> "$WT/.launch-state"; led PUSHED "$PROD ${BASE:0:7} -> ${TIP:0:7}"
}
# The domain's fingerprint BEFORE the push lets the live check tell whether the site changed afterwards. Taken first,
# so the last checks below run right before the push.
DOMAIN="$(node "$S/cfg.mjs" "$R" domain "" 2>/dev/null)"
[ -n "$DOMAIN" ] && printf 'ETAG_BEFORE=%q\n' "$(bash "$S/etag.sh" "$DOMAIN" "$WT/.launch-before.html")" >> "$WT/.launch-state"

git -C "$R" fetch origin -q || { echo "NOT PUSHED: fetch failed (network?). Nothing changed."; exit 1; }
cur="$(git -C "$R" rev-parse --verify -q "refs/remotes/origin/$PROD")"
if [ "$cur" = "$T" ]; then pushed; echo "PUSHED_OK  Ship $CODE · origin already had ${T:0:7} on $PROD"; exit 0; fi
if [ "$cur" != "$BASE" ]; then
  echo "NOT PUSHED: PROD_MOVED. $PROD on origin is ${cur:0:7}, but it was ${BASE:0:7} when this release started: someone"
  echo "pushed or rolled it back. Clean up, bring your branch up to date, and run /launchcodes again."; exit 1
fi
git -c core.quotePath=false -C "$R" diff --name-only --no-renames "$BASE" "$T" | diff -q - "$WT/.launch-approved-files" >/dev/null \
  || { echo "NOT PUSHED: FILES_CHANGED. The files differ from the ones the owner approved. Show the plan again."; exit 1; }
node "$S/never_ships.mjs" "$R" "$BASE" "$T" "$PROD" >/dev/null 2>&1 || { echo "NOT PUSHED: the secret-file check no longer passes (run check.sh)"; exit 1; }
node "$S/secret_scan.mjs" "$R" "$BASE" "$T" "$PROD" >/dev/null 2>&1 || { echo "NOT PUSHED: the keys-in-code check no longer passes (run check.sh)"; exit 1; }

# The release commit: a merge commit whose first parent is what's live and whose second is the release, holding
# exactly the files that were built and checked. Your host builds it and shows its subject, the release's name.
if [ "${RELEASE_COMMIT:-}" = true ]; then
  { printf 'Ship %s · %s\n\n' "$CODE" "${SHIP_NAME:-release}"
    echo "Released with /launchcodes after the owner's yes to the plan."
    echo; echo "Commits in this release:"
    git -C "$R" log --reverse --no-merges --format='  %h %s' "$BASE..$T" | head -40; } > "$WT/.launch-release-msg"
  TIP="$(git -C "$R" commit-tree "$T^{tree}" -p "$BASE" -p "$T" -F "$WT/.launch-release-msg" 2> "$WT/.launch-release-err")" \
    && [ "$(git -C "$R" rev-parse "$TIP^{tree}" 2>/dev/null)" = "$TREE" ] \
    || { echo "NOT PUSHED: couldn't make the release commit: $(head -3 "$WT/.launch-release-err" 2>/dev/null)"; exit 1; }
fi

git -C "$R" push --no-follow-tags --recurse-submodules=no origin "$TIP:refs/heads/$PROD" > "$WT/.launch-push.log" 2>&1; rc=$?
cat "$WT/.launch-push.log"
git -C "$R" fetch origin -q
now="$(git -C "$R" rev-parse --verify -q "refs/remotes/origin/$PROD")"
if [ "$now" = "$TIP" ]; then
  pushed
  [ $rc -ne 0 ] && echo "(git reported exit $rc, but GitHub has the commit)"
  echo "PUSHED_OK  Ship $CODE · ${SHIP_NAME:-} · $PROD is now ${TIP:0:7}"
  echo "NEXT: live check"; exit 0
fi
if [ -n "$now" ] && [ "$now" != "$BASE" ] && git -C "$R" merge-base --is-ancestor "$TIP" "$now" 2>/dev/null; then
  pushed
  echo "PUSHED_OK  Ship $CODE · ${TIP:0:7} is on $PROD, and someone pushed on top of it right after (now ${now:0:7})."
  echo "NEXT: live check (your host may build only the newer commit)"; exit 0
fi
if [ $rc -ne 0 ]; then echo "NOT PUSHED: git push failed (exit $rc). Nothing changed. Never retry with --force."; exit 1; fi
echo "PUSH UNCLEAR: $PROD on origin is ${now:0:7}, expected ${TIP:0:7}. Look before doing anything else."
exit 1
