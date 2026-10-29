#!/usr/bin/env bash
# candidates.sh <repo>
# /launchcodes with no commit. Read-only: lists the releases that could go live now, newest first and numbered, so
# the owner picks one instead of Claude guessing from the conversation. A release here is a branch (yours or on
# origin) whose newest commit isn't live yet and sits on top of what is live (with "releaseCommit": on top of it
# apart from earlier release commits). Branches with unreleased work that would need updating first are counted.
# Exit: 0 list printed | 1 NOTHING_READY | 3 setup problem
set -u
S="$(cd "$(dirname "$0")" && pwd)"
R="$(git -C "${1:?usage: candidates.sh <repo>}" rev-parse --show-toplevel 2>/dev/null)" || { echo "NOT A GIT REPO: $1"; exit 3; }
g() { git -C "$R" "$@"; }
msg="$(node "$S/cfg.mjs" "$R" --check)" || { echo "$msg"; exit 3; }
PROD="$(node "$S/cfg.mjs" "$R" prodBranch "")"; RC="$(node "$S/cfg.mjs" "$R" releaseCommit "")"
g fetch origin -q || { echo "FETCH_FAILED: git could not reach origin."; exit 3; }
[ -z "$PROD" ] && PROD="$(g symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
[ -z "$PROD" ] && PROD=main
BASE="$(g rev-parse --verify -q "refs/remotes/origin/$PROD^{commit}")" || { echo "NO BRANCH $PROD on origin: set \"prodBranch\" in .claude/launchcodes.json."; exit 3; }
rel_only() {   # same rule as prepare.sh: beyond $1, $PROD holds release commits only, which add no files
  local mb; mb="$(g merge-base "$BASE" "$1" 2>/dev/null)" || return 1
  [ "$(g rev-parse "$BASE^{tree}")" = "$(g rev-parse "$mb^{tree}")" ] || return 1
  ! g log --first-parent --format='%p%x09%s' "$mb..$BASE" | grep -vE '^[0-9a-f]+ [0-9a-f]+	Ship [0-9]{2}[A-Za-z]{3}-[0-9]+ ' | grep -q .
}
n=0; behind=0; seen=" "
while IFS=$'\t' read -r sha ref when subj; do
  name="${ref#refs/heads/}"; name="${name#refs/remotes/}"
  case "$name" in "$PROD"|"origin/$PROD"|origin/HEAD) continue ;; esac
  case "$seen" in *" $sha "*) continue ;; esac
  seen="$seen$sha "
  g merge-base --is-ancestor "$sha" "$BASE" && continue                 # already live
  if g merge-base --is-ancestor "$BASE" "$sha" || { [ "$RC" = true ] && rel_only "$sha"; }; then
    [ $n -ge 9 ] && { n=$((n + 1)); continue; }
    n=$((n + 1))
    c="$(g rev-list --count --no-merges "$BASE..$sha")"
    files="$(g -c core.quotePath=false diff --name-only --no-renames "$BASE" "$sha")"
    m="$(printf '%s\n' "$files" | grep -cE '(^|/)(supabase/migrations|prisma/migrations|migrations|db/migrate)/')"
    e="$(printf '%s\n' "$files" | sed -nE 's#^(.*/)?supabase/functions/([^/]+)/.*#\2#p' | sort -u | grep -c .)"
    extra=""; [ "$m" -gt 0 ] && extra=" · $m database file(s)"; [ "$e" -gt 0 ] && extra="$extra · $e edge function(s)"
    [ "$c" = 1 ] && cw=commit || cw=commits
    printf '  %d  %s  %s  %s %s · %s%s\n      newest: %s\n' "$n" "$name" "${sha:0:7}" "$c" "$cw" "$when" "$extra" "$(printf '%s' "$subj" | cut -c1-90)"
    echo "PICK $n = $sha"
  else
    behind=$((behind + 1))
  fi
done <<EOF
$(g for-each-ref --sort=-committerdate --format='%(objectname)%09%(refname)%09%(committerdate:format:%d %b %H:%M)%09%(subject)' refs/heads refs/remotes/origin)
EOF
[ $n -gt 9 ] && echo "  ... and $((n - 9)) more: name one with  /launchcodes <commit>"
[ $behind -gt 0 ] && echo "NOT LISTED: $behind other branch(es) with commits $PROD doesn't have, that don't sit on top of it (older work, or work that needs updating first)."
if [ $n -eq 0 ]; then
  echo "NOTHING_READY: no branch holds commits that can go live on top of $PROD (${BASE:0:7}). Commit your work, or bring"
  echo "your branch up to date with $PROD, then run /launchcodes again."
  exit 1
fi
echo "RELEASES READY: $n on top of $PROD (${BASE:0:7}). The owner picks one by its number."
