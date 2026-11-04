#!/usr/bin/env bash
# wait_live.sh <WT> [timeout_s=480]
# Runs in the foreground: everything, retries included, ends within about timeout_s + 60 seconds.
# Step 6. Confirms that production serves the pushed commit. It watches two things at once:
#   - your host's PRODUCTION deployment of the commit, as GitHub records it (needs the GitHub CLI, gh, logged in;
#     Vercel and others report there), and
#   - your site itself, if "domain" or "liveUrl" is set. That works with any host and any git server, and for a
#     release your own "deployCommand" put live. When GitHub can't be asked, or records nothing, it is the whole check.
# Why not "the URL returns 200"? Single-page apps answer 200 for every path, so that proves nothing.
# It says LIVE only on real evidence, new since the push: your home page, a script it loads, or your "liveUrl" page
# shows this release's commit id (many builds stamp it); or your home page loads a file only this build has (a
# content-hashed name like index-DZhMrgGv.js); or it has the same fingerprint (ETag) as the deployment's own address.
# Anything weaker is DEPLOYED, with the reason. A failed deployment is reported with your host's own reason and link.
# One verdict, then exit:
#   0 LIVE          your site serves this release
#   0 DEPLOYED      your host finished the production build; your site wasn't confirmed (the line says why)
#   1 BUILD_FAILED  your host's build failed (or DEPLOY_FAILED: your deployCommand did): the previous version is
#                   still live, but the branch has the new commit
#   2 TIMEOUT · 3 bad input or GitHub unreachable · 4 NO_DEPLOYMENT_REPORTED · 5 NOT_CONFIRMED · 6 NO_GH
set -u
WT="${1:?usage: wait_live.sh <WT> [timeout_s]}"; TIMEOUT="${2:-480}"
POLL="${POLL:-15}"; GRACE="${GRACE:-180}"; RETRY_SLEEP="${RETRY_SLEEP:-15}"
[ -f "$WT/.launch-state" ] || { echo "NO STATE in $WT"; exit 3; }
. "$WT/.launch-state"
[ -n "${PUSHED:-}" ] || { echo "NOT PUSHED YET: there's nothing to wait for"; exit 3; }
SHA="${PUSHED%% *}"; start=$(date +%s); el=0
led() { printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M %Z')" "$CODE" "$1" "$2" >> "$LOG" 2>/dev/null; }
now() { date '+%H:%M %Z'; }
DOMAIN="$(node "$S/cfg.mjs" "$R" domain "")" || { echo "SETUP: $DOMAIN"; exit 3; }
LIVEURL="$(node "$S/cfg.mjs" "$R" liveUrl "")" || { echo "SETUP: $LIVEURL"; exit 3; }
HOST="${DOMAIN#*://}"; HOST="${HOST%%/*}"
case "$LIVEURL" in /*) LIVEURL="https://$HOST$LIVEURL" ;; esac      # a path is on your domain
SITE="${DOMAIN:-$LIVEURL}"
IDS="${SHA:0:7}"; [ "${T:0:7}" != "${SHA:0:7}" ] && IDS="$IDS ${T:0:7}"

# push.sh said DEPLOY_FAILED: your deployCommand failed after the push. A short look at your site, then the verdict.
dfail=""; case "${DEPLOY_CMD:-}" in failed*) dfail="${DEPLOY_CMD#failed }"; [ "$TIMEOUT" -gt 60 ] && TIMEOUT=60 ;; esac
deploy_failed() {
  # (No apostrophes inside ${...:+...}: bash reads one there as an opening quote.)
  echo "DEPLOY_FAILED: your deployCommand failed (exit $dfail) after the push${SITE:+, and $SITE does not show this release}."
  echo "The previous version is probably still live, but $PROD has the new commit. Fix what its log showed, then run"
  echo "your deploy yourself."
  led FAILED "deployCommand exit $dfail"; exit 1
}

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
# This release's commit id, written into the page or into a script it loads (many builds stamp it, from
# `git rev-parse HEAD` or the host's commit variable). Matched only as a whole quoted string, so a chance match
# in minified code is all but impossible. Prints the id it found.
has_id() {
  local c
  for c in $IDS; do grep -qE "[\"'\`]$c[0-9a-f]{0,33}[\"'\`]" "$1" 2>/dev/null && { echo "$c"; return 0; }; done
  grep -qF "$SHA" "$1" 2>/dev/null && { echo "${SHA:0:7}"; return 0; }
  return 1
}
# Your "liveUrl" page exists to name the version, so there the id may stand on its own: a whole word is enough.
has_word_id() {
  local c
  for c in $IDS; do grep -qiE "(^|[^0-9a-f])$c[0-9a-f]{0,33}([^0-9a-f]|$)" "$1" 2>/dev/null && { echo "$c"; return 0; }; done
  return 1
}
# Prints "liveurl <id>" or "page <id>" when your liveUrl page, your home page ($1) or a script it loads names this
# release. A script whose name carries a content hash is read once per run: the same name is the same file.
HASHED='[-.][A-Za-z0-9_-]{8,}\.m?js$'
: > "$WT/.launch-read-scripts"
stamp_hit() {
  local src u n=0 st id
  if [ -n "$LIVEURL" ]; then
    bash "$S/etag.sh" "$LIVEURL" "$WT/.launch-liveurl.txt" >/dev/null
    id="$(has_word_id "$WT/.launch-liveurl.txt")" && { echo "liveurl $id"; return 0; }
  fi
  [ -s "$1" ] || return 1
  id="$(has_id "$1")" && { echo "page $id"; return 0; }
  for src in $(grep -oE '<script[^>]+src="[^"]+"' "$1" 2>/dev/null | sed -E 's/.*src="([^"]+)".*/\1/' | head -3); do
    case "$src" in http*) u="$src" ;; //*) u="https:$src" ;; /*) u="https://$HOST$src" ;; *) u="https://$HOST/$src" ;; esac
    grep -qxF -- "$u" "$WT/.launch-read-scripts" && continue
    n=$((n + 1)); read -r st _ <<<"$(bash "$S/etag.sh" "$u" "$WT/.launch-script-$n.js")"
    id="$(has_id "$WT/.launch-script-$n.js")" && { echo "page $id"; return 0; }
    case "$st" in 2*) [[ "$u" =~ $HASHED ]] && echo "$u" >> "$WT/.launch-read-scripts" ;; esac
  done
  return 1
}
say_live() {    # $1: what stamp_hit printed
  case "$1" in
    liveurl*) echo "LIVE: ${DOMAIN:-your site} serves ${SHA:0:7}: $LIVEURL shows this release's commit id, ${1#* } ($(now))" ;;
    *) echo "LIVE: $DOMAIN serves ${SHA:0:7}: it carries this release's commit id, ${1#* } ($(now))" ;;
  esac
  led LIVE "$(now)"; exit 0
}
# One look at your site, for proof only (this release's commit id, or a file only this build has). LIVE ends the run.
LAST_ST=""
site_proof() {
  local hit a
  : > "$WT/.launch-now.html"
  [ -n "$DOMAIN" ] && read -r LAST_ST _ <<<"$(bash "$S/etag.sh" "$DOMAIN" "$WT/.launch-now.html")"
  if hit="$(stamp_hit "$WT/.launch-now.html")"; then say_live "$hit"; fi
  if a="$(new_asset "$WT/.launch-now.html")"; then
    echo "LIVE: $DOMAIN serves ${SHA:0:7}: its home page now loads $a, a file only this build has ($(now))"; led LIVE "$(now)"; exit 0
  fi
  return 1
}
# The time limit passed, and your site showed no proof.
site_timeout() {
  local how="${why:+ ($why, so I watched your site itself)}" hint=""
  [ -n "$dfail" ] && deploy_failed
  if [ -z "$LIVEURL" ] && { [ ! -s "$WT/.launch-assets" ] || [ ! -s "$WT/.launch-before.html" ]; }; then
    hint="To let launchcodes confirm it next time: set \"liveUrl\" to a page that shows the commit id (like /version.txt), or have your build write the commit id into your home page."
  fi
  if [ -n "$DOMAIN" ] && [ "${LAST_ST:-000}" = 000 ]; then
    echo "TIMEOUT after ${el}s: $DOMAIN didn't answer$how. Look at it yourself, and at your host's dashboard."
    led UNCONFIRMED "timeout, site didn't answer"; exit 2
  fi
  if [ -s "$WT/.launch-before.html" ] && [ -s "$WT/.launch-now.html" ] && ! cmp -s "$WT/.launch-before.html" "$WT/.launch-now.html"; then
    echo "NOT_CONFIRMED after ${el}s: $DOMAIN changed after the push, but nothing on it names ${SHA:0:7} or loads a file only"
    echo "this build has, so I can't tell it's this release$how. Have a look at $DOMAIN yourself."
    [ -n "$hint" ] && echo "$hint"
    led UNCONFIRMED "site changed, no proof"; exit 5
  fi
  echo "TIMEOUT after ${el}s: $SITE doesn't show ${SHA:0:7} yet$how. If your host is still deploying, look again in a few minutes."
  [ -n "$hint" ] && echo "$hint"
  led UNCONFIRMED "timeout, no sign of it on the site"; exit 2
}

# Can GitHub tell us about the deployment? If not, your site is the whole check.
GH=0; why=""
REPO="$(git -C "$R" config --get remote.origin.url | sed -nE 's#^.*github\.com[:/]+([^/]+/[^/]+)$#\1#p' | sed 's#\.git$##')"
if [ -z "$REPO" ]; then why="origin isn't on GitHub"
elif ! command -v gh >/dev/null 2>&1; then why="the GitHub CLI (gh) isn't installed"
elif ! gh auth status >/dev/null 2>&1; then why="the GitHub CLI (gh) isn't logged in"
else
  ahead="$(gh api "repos/$REPO/compare/$PROD...$SHA" --jq .status 2>/dev/null)"
  case "$ahead" in
    identical|behind) GH=1 ;;
    "") why="GitHub didn't answer about ${SHA:0:7} (network, or a rate limit)" ;;
    *) echo "NOT ON $PROD: GitHub's $PROD doesn't contain ${SHA:0:7} (compare: $ahead), so no production build will come."; led UNCONFIRMED "not on $PROD"; exit 3 ;;
  esac
fi
if [ $GH = 0 ] && [ -z "$SITE" ]; then
  [ -n "$dfail" ] && deploy_failed
  tip="Check your host's dashboard (or set \"domain\" in .claude/launchcodes.json, and I'll watch your site itself next time)."
  case "$why" in
    origin*) echo "NOT GITHUB: $why, so I can't see deployments. $tip"; led UNCONFIRMED "not github"; exit 3 ;;
    *CLI*)   echo "NO_GH: $why, so I can't see the deployment. $tip"; led UNCONFIRMED "no gh"; exit 6 ;;
    *)       echo "GITHUB UNREACHABLE: $why. Check your host's dashboard."; led UNCONFIRMED "github unreachable"; exit 3 ;;
  esac
fi
[ $GH = 0 ] && echo "Watching $SITE itself: $why."

seen=0
while :; do
  el=$(( $(date +%s) - start ))
  if [ $GH = 1 ]; then
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
          if [ -z "$SITE" ]; then
            echo "DEPLOYED: your host finished the production build of ${SHA:0:7} ($(now)). Your site wasn't checked: set \"domain\" in .claude/launchcodes.json to check it next time."
            led DEPLOYED "$(now)"; exit 0
          fi
          before="${ETAG_BEFORE:-000 }"; before_tag="${before#* }"; note=""; other=0; body="$WT/.launch-now.html"
          for i in 1 2 3 4 5 6; do
            dst=000; dtag=""; : > "$body"
            [ -n "$DOMAIN" ] && read -r dst dtag <<<"$(bash "$S/etag.sh" "$DOMAIN" "$body")"
            if hit="$(stamp_hit "$body")"; then say_live "$hit"; fi
            if a="$(new_asset "$body")"; then
              echo "LIVE: $DOMAIN serves ${SHA:0:7}: its home page now loads $a, a file only this build has ($(now))"; led LIVE "$(now)"; exit 0
            fi
            other=0; ust=000; utag=""
            if [ -z "$DOMAIN" ]; then note="$LIVEURL doesn't show its commit id"
            else
              [ "$url" != "-" ] && read -r ust utag <<<"$(bash "$S/etag.sh" "$url")"
              case "$ust" in 2*) ;; *) utag="" ;; esac       # only a 2xx answer from the deployment's own address counts
              if [ -n "$dtag" ] && [ -n "$utag" ]; then
                if [ "$dtag" != "$utag" ]; then other=1; note=""
                elif [ -n "$before_tag" ] && [ "$dtag" = "$before_tag" ]; then note="your home page is the same before and after this release, so it can't show which build $DOMAIN serves"
                else echo "LIVE: $DOMAIN serves ${SHA:0:7}: same fingerprint as the new deployment ($(now))"; led LIVE "$(now)"; exit 0; fi
              elif [ -z "$dtag" ]; then note="$DOMAIN answered (HTTP $dst) without a fingerprint and without a file from this build, so I can't compare it"
              elif [ -n "$before_tag" ] && [ "$dtag" != "$before_tag" ]; then note="$DOMAIN changed after the push, but its home page doesn't load a file from this build (your host's build may differ, for example through environment variables) and the deployment's own address couldn't be compared"
              else note="your home page didn't change, and the deployment's own address couldn't be compared (HTTP $ust)"; fi
            fi
            [ "$i" -lt 6 ] || break
            [ $(( $(date +%s) - start + RETRY_SLEEP )) -le $(( TIMEOUT + 5 )) ] || break   # stay inside the caller's time limit
            sleep "$RETRY_SLEEP"
          done
          if [ "$other" = 1 ]; then
            echo "NOT_CONFIRMED: your host built ${SHA:0:7}, but $DOMAIN serves a different build: a newer push, an Instant Rollback (undo it in"
            echo "your host's dashboard), or the domain isn't assigned to production. Check your host's dashboard."
            led UNCONFIRMED "domain serves another build"; exit 5
          fi
          [ -n "$DOMAIN" ] && [ -n "$LIVEURL" ] && note="$note; and $LIVEURL doesn't show its commit id"
          echo "DEPLOYED: your host finished the production build of ${SHA:0:7} ($(now)), but $note. Have a look at $SITE yourself."
          led DEPLOYED "unconfirmed: $note"; exit 0 ;;
        failure|error)
          # The deployment's own status is often terse ("Deployment was blocked"); the commit's statuses say why.
          says="$(gh api "repos/$REPO/commits/$SHA/statuses" --jq '[.[] | select(.state == "failure" or .state == "error") | (.description // "") + "\t" + (.target_url // "")] | unique | .[0:3][]' 2>/dev/null)"
          echo "BUILD_FAILED: your host didn't put ${SHA:0:7} live ($desc). The previous version is still live, but $PROD now has"
          echo "the new commit."
          if [ -n "$says" ]; then
            echo "Your host says:"; printf '%s\n' "$says" | while IFS=$'\t' read -r d u; do echo "   $d${u:+  ($u)}"; done
          fi
          if printf '%s %s' "$desc" "$says" | grep -qiE 'blocked|access|permission|not allowed|unauthori|seat|limit'; then
            echo "That is your host REFUSING the deployment (an account, team or plan setting), not a fault in your code. Fix the"
            echo "setting at your host, then redeploy from its dashboard or run /launchcodes again."
          else
            echo "Fix it and run /launchcodes again, or revert it. Your host's dashboard has the build log."
          fi
          led FAILED "$state"; exit 1 ;;
        inactive)
          echo "NOT_CONFIRMED: a newer production deployment already replaced ${SHA:0:7}. Check your host's dashboard for what's live now."
          led UNCONFIRMED superseded; exit 5 ;;
      esac
    fi
  fi
  # No finished production deployment on GitHub (yet): your site itself may already show this release.
  [ -n "$SITE" ] && site_proof
  if [ $GH = 1 ] && [ $seen = 0 ] && [ $el -ge "$GRACE" ]; then
    n="$(gh api "repos/$REPO/commits/$SHA/statuses" --jq 'length' 2>/dev/null)"
    if [ "${n:-0}" = 0 ]; then
      if [ -n "$SITE" ]; then
        GH=0; why="your host reports nothing to GitHub"; echo "  your host reports nothing to GitHub, so from here on I watch $SITE itself"
      else
        [ -n "$dfail" ] && deploy_failed
        echo "NO_DEPLOYMENT_REPORTED after ${el}s: your host may not report deployments to GitHub. Check its dashboard (or set"
        echo "\"domain\" in .claude/launchcodes.json, and I'll watch your site itself next time)."
        led UNCONFIRMED "no deployment reported"; exit 4
      fi
    fi
  fi
  if [ $el -ge "$TIMEOUT" ]; then
    [ -n "$dfail" ] && deploy_failed
    if [ $GH = 1 ]; then
      # Vercel records the deployment only when it's done, but marks the commit "pending" while it builds: a slow build
      # (queued behind others, or just long) looks like nothing happening. Its own status tells the two apart.
      IFS=$'\t' read -r pst pdesc <<<"$(gh api "repos/$REPO/commits/$SHA/statuses" --jq '.[0] // empty | [.state, (.description // "")] | @tsv' 2>/dev/null)"
      if [ "${pst:-}" = pending ]; then
        echo "TIMEOUT after ${el}s, STILL BUILDING: your host is still deploying ${SHA:0:7} (it says: ${pdesc:-pending})."
        echo "Builds sometimes queue or run long: run the live check once more."
        led UNCONFIRMED "timeout, still building"; exit 2
      fi
      if [ $seen = 0 ] && [ -n "$SITE" ]; then why="your host recorded no deployment on GitHub"; site_timeout; fi
      echo "TIMEOUT after ${el}s: your host hasn't finished yet. Check its dashboard."; led UNCONFIRMED timeout; exit 2
    fi
    site_timeout
  fi
  if [ $GH = 1 ]; then echo "  ...waiting for the production build (${el}s)"; else echo "  ...waiting for $SITE to serve it (${el}s)"; fi
  sleep "$POLL"
done
