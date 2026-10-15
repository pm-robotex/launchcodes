#!/usr/bin/env bash
# wait_live.sh <WT> [timeout_s=480]
# Runs in the foreground: everything, retries included, ends within about timeout_s + 60 seconds.
# Step 6. Waits for your host's PRODUCTION deployment of the pushed commit and, if "domain" is set, checks that
# your domain now serves it. Needs the GitHub CLI (gh), logged in, and a host that reports deployments to GitHub
# (Vercel does). Why not "the URL returns 200"? Single-page apps answer 200 for every path, so that proves nothing.
# It says LIVE only on real evidence, new since the push: your home page loads a file only this build has (a
# content-hashed name like index-DZhMrgGv.js), or it has the same fingerprint (ETag) as the deployment's own
# address. Anything weaker is DEPLOYED, with the reason.
# One verdict, then exit:
#   0 LIVE          your domain serves the new deployment
#   0 DEPLOYED      your host finished the production build; your domain wasn't confirmed (the line says why)
#   1 BUILD_FAILED  the host's build failed: the previous version is still live, but the branch has the new commit
#   2 TIMEOUT · 3 bad input or GitHub unreachable · 4 NO_DEPLOYMENT_REPORTED · 5 NOT_CONFIRMED · 6 NO_GH
set -u
WT="${1:?usage: wait_live.sh <WT> [timeout_s]}"; TIMEOUT="${2:-480}"
POLL="${POLL:-15}"; GRACE="${GRACE:-180}"; RETRY_SLEEP="${RETRY_SLEEP:-15}"
[ -f "$WT/.launch-state" ] || { echo "NO STATE in $WT"; exit 3; }
. "$WT/.launch-state"
[ -n "${PUSHED:-}" ] || { echo "NOT PUSHED YET: there's nothing to wait for"; exit 3; }
SHA="${PUSHED%% *}"
led() { printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M %Z')" "$CODE" "$1" "$2" >> "$LOG" 2>/dev/null; }
now() { date '+%H:%M %Z'; }
if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
  echo "NO_GH: the GitHub CLI (gh) isn't installed or logged in, so I can't see the deployment. Check your host's dashboard."
  led UNCONFIRMED "no gh"; exit 6
fi
REPO="$(git -C "$R" config --get remote.origin.url | sed -nE 's#^.*github\.com[:/]+([^/]+/[^/]+)$#\1#p' | sed 's#\.git$##')"
[ -n "$REPO" ] || { echo "NOT GITHUB: origin isn't a GitHub repo, so I can't see deployments. Check your host's dashboard."; led UNCONFIRMED "not github"; exit 3; }
DOMAIN="$(node "$S/cfg.mjs" "$R" domain "" 2>/dev/null)"
cmp="$(gh api "repos/$REPO/compare/$PROD...$SHA" --jq .status 2>/dev/null)"
case "$cmp" in
  identical|behind) ;;
  "") echo "GITHUB UNREACHABLE: I couldn't ask GitHub about ${SHA:0:7} (network, or a rate limit). Check your host's dashboard."; led UNCONFIRMED "github unreachable"; exit 3 ;;
  *) echo "NOT ON $PROD: GitHub's $PROD doesn't contain ${SHA:0:7} (compare: $cmp), so no production build will come."; led UNCONFIRMED "not on $PROD"; exit 3 ;;
esac

# A file this build made that the domain didn't serve before the push: proof the domain switched to this build.
# Needs the page from before the push: without it, "new" can't be told from "was always there".
new_asset() {
  [ -s "$WT/.launch-assets" ] && [ -s "$WT/.launch-before.html" ] && [ -s "$1" ] || return 1
  while IFS= read -r a; do
    [ -z "$a" ] && continue
    if grep -qF -- "$a" "$1" && ! grep -qF -- "$a" "$WT/.launch-before.html"; then echo "$a"; return 0; fi
  done < "$WT/.launch-assets"
  return 1
}

start=$(date +%s); seen=0
while :; do
  el=$(( $(date +%s) - start ))
  ids="$(gh api "repos/$REPO/deployments?sha=$SHA&per_page=30" --jq '.[] | select((.environment // "") | test("production"; "i")) | .id' 2>/dev/null)"
  [ -n "$ids" ] && seen=1
  res=""
  for id in $ids; do
    line="$(gh api "repos/$REPO/deployments/$id/statuses?per_page=1" --jq '.[0] // empty | [.created_at, .state, ((.environment_url // "") | if . == "" then "-" else . end), ((.description // "") | if . == "" then "-" else . end)] | @tsv' 2>/dev/null)"
    [ -n "$line" ] && res="$res$line"$'\n'
  done
  res="$(printf '%s' "$res" | sort | tail -1)"
  if [ -n "$res" ]; then
    IFS=$'\t' read -r at state url desc <<<"$res"
    case "$state" in
      success)
        if [ -z "$DOMAIN" ]; then
          echo "DEPLOYED: your host finished the production build of ${SHA:0:7} ($(now)). Your domain wasn't checked: set \"domain\" in .claude/launchcodes.json to check it next time."
          led DEPLOYED "$(now)"; exit 0
        fi
        before="${ETAG_BEFORE:-000 }"; before_tag="${before#* }"; note=""; other=0; body="$WT/.launch-now.html"
        for i in 1 2 3 4 5 6; do
          read -r dst dtag <<<"$(bash "$S/etag.sh" "$DOMAIN" "$body")"; ust="000"; utag=""
          if a="$(new_asset "$body")"; then
            echo "LIVE: $DOMAIN serves ${SHA:0:7}: its home page now loads $a, a file only this build has ($(now))"; led LIVE "$(now)"; exit 0
          fi
          [ "$url" != "-" ] && read -r ust utag <<<"$(bash "$S/etag.sh" "$url")"
          case "$ust" in 2*) ;; *) utag="" ;; esac       # only a 2xx answer from the deployment's own address counts
          other=0
          if [ -n "$dtag" ] && [ -n "$utag" ]; then
            if [ "$dtag" != "$utag" ]; then other=1; note=""
            elif [ -n "$before_tag" ] && [ "$dtag" = "$before_tag" ]; then note="your home page is the same before and after this release, so it can't show which build $DOMAIN serves"
            else echo "LIVE: $DOMAIN serves ${SHA:0:7}: same fingerprint as the new deployment ($(now))"; led LIVE "$(now)"; exit 0; fi
          elif [ -z "$dtag" ]; then note="$DOMAIN answered (HTTP $dst) without a fingerprint and without a file from this build, so I can't compare it"
          elif [ -n "$before_tag" ] && [ "$dtag" != "$before_tag" ]; then note="$DOMAIN changed after the push, but its home page doesn't load a file from this build (your host's build may differ, for example through environment variables) and the deployment's own address couldn't be compared"
          else note="your home page didn't change, and the deployment's own address couldn't be compared (HTTP $ust)"; fi
          [ "$i" -lt 6 ] || break
          [ $(( $(date +%s) - start + RETRY_SLEEP )) -le $(( TIMEOUT + 5 )) ] || break   # stay inside the caller's time limit
          sleep "$RETRY_SLEEP"
        done
        if [ "$other" = 1 ]; then
          echo "NOT_CONFIRMED: your host built ${SHA:0:7}, but $DOMAIN serves a different build: a newer push, an Instant Rollback (undo it in"
          echo "your host's dashboard), or the domain isn't assigned to production. Check your host's dashboard."
          led UNCONFIRMED "domain serves another build"; exit 5
        fi
        echo "DEPLOYED: your host finished the production build of ${SHA:0:7} ($(now)), but $note. Have a look at $DOMAIN yourself."
        led DEPLOYED "unconfirmed: $note"; exit 0 ;;
      failure|error)
        echo "BUILD_FAILED: your host's production build of ${SHA:0:7} failed ($desc). The previous version is still live, but $PROD"
        echo "now has the new commit. Fix it and run /launchcodes again, or revert it. Your host's dashboard has the build log."
        led FAILED "$state"; exit 1 ;;
      inactive)
        echo "NOT_CONFIRMED: a newer production deployment already replaced ${SHA:0:7}. Check your host's dashboard for what's live now."
        led UNCONFIRMED superseded; exit 5 ;;
    esac
  fi
  if [ $seen = 0 ] && [ $el -ge "$GRACE" ]; then
    n="$(gh api "repos/$REPO/commits/$SHA/statuses" --jq 'length' 2>/dev/null)"
    if [ "${n:-0}" = 0 ]; then
      echo "NO_DEPLOYMENT_REPORTED after ${el}s: your host may not report deployments to GitHub. Check its dashboard."
      led UNCONFIRMED "no deployment reported"; exit 4
    fi
  fi
  [ $el -ge "$TIMEOUT" ] && { echo "TIMEOUT after ${el}s: your host hasn't finished yet. Check its dashboard."; led UNCONFIRMED timeout; exit 2; }
  echo "  ...waiting for the production build (${el}s)"; sleep "$POLL"
done
