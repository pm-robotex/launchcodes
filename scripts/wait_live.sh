#!/usr/bin/env bash
# wait_live.sh <WT> [timeout_s=480]
# Runs in the foreground: everything, retries included, ends within about timeout_s + 60 seconds.
# Step 6. Confirms that production serves the pushed commit. It watches two things at once:
#   - your host's PRODUCTION deployments of the commit, as GitHub records them (needs the GitHub CLI, gh, logged in;
#     Vercel and others report there). One repo can feed several projects (say a web app and an API on Vercel): each
#     reports its own deployment, and EVERY one must succeed. While any is still building it waits; if any fails, the
#     release failed, even when another one built fine.
#   - your site itself, if "domain" or "liveUrl" is set. That works with any host and any git server, and for a
#     release your own "deployCommand" put live. When GitHub can't be asked, or records nothing, it is the whole check.
# Why not "the URL returns 200"? Single-page apps answer 200 for every path, so that proves nothing.
# LIVE needs real evidence, new since the push, from EVERY place your site is served from: each "liveUrl" page must
# show this release's commit id; and your domain must carry it too (in its page or a script it loads), or load a file
# only this build has (a content-hashed name like index-DZhMrgGv.js), or have the same fingerprint (ETag) as a new
# deployment's own address, unless a liveUrl on the same host already speaks for it. Anything weaker is DEPLOYED, with
# the reason. A failed deployment is reported with your host's own reason and link.
# One verdict, then exit:
#   0 LIVE          your site serves this release
#   0 DEPLOYED      your host finished every production build; your site wasn't confirmed (the line says why)
#   1 BUILD_FAILED  a production build failed (or DEPLOY_FAILED: your deployCommand did): the previous version is still
#                   live there, but the branch has the new commit
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
lu="$(node "$S/cfg.mjs" "$R" liveUrl "")" || { echo "SETUP: $lu"; exit 3; }
HOST="${DOMAIN#*://}"; HOST="${HOST%%/*}"
LIVEURLS=""
while IFS= read -r u; do
  [ -z "$u" ] && continue
  case "$u" in /*) u="https://$HOST$u" ;; esac          # a path is on your domain
  LIVEURLS="$LIVEURLS$u"$'\n'
done <<EOF
$lu
EOF
SITE="${DOMAIN:-$(printf '%s' "$LIVEURLS" | head -1)}"
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
# A "liveUrl" page exists to name the version, so there the id may stand on its own: a whole word is enough.
has_word_id() {
  local c
  for c in $IDS; do grep -qiE "(^|[^0-9a-f])$c[0-9a-f]{0,33}([^0-9a-f]|$)" "$1" 2>/dev/null && { echo "$c"; return 0; }; done
  return 1
}
# The commit id in your home page ($1) or one of the first scripts it loads. A script whose name carries a content
# hash is read once per run: the same name is the same file.
HASHED='[-.][A-Za-z0-9_-]{8,}\.m?js$'
: > "$WT/.launch-read-scripts"
page_id() {
  local src u n=0 st id
  [ -s "$1" ] || return 1
  id="$(has_id "$1")" && { echo "$id"; return 0; }
  for src in $(grep -oE '<script[^>]+src="[^"]+"' "$1" 2>/dev/null | sed -E 's/.*src="([^"]+)".*/\1/' | head -3); do
    case "$src" in http*) u="$src" ;; //*) u="https:$src" ;; /*) u="https://$HOST$src" ;; *) u="https://$HOST/$src" ;; esac
    grep -qxF -- "$u" "$WT/.launch-read-scripts" && continue
    n=$((n + 1)); read -r st _ <<<"$(bash "$S/etag.sh" "$u" "$WT/.launch-script-$n.js")"
    id="$(has_id "$WT/.launch-script-$n.js")" && { echo "$id"; return 0; }
    case "$st" in 2*) [[ "$u" =~ $HASHED ]] && echo "$u" >> "$WT/.launch-read-scripts" ;; esac
  done
  return 1
}
# The domain's fingerprint against each new deployment's own address (only a 2xx answer counts). Returns 0 on a
# match that is new since the push; otherwise sets DNOTE (why not) and DOMAIN_OTHER (it serves another build).
fingerprint() {
  local env url ust utag compared=0 before="${ETAG_BEFORE:-000 }" btag
  btag="${before#* }"
  [ -n "$DTAG" ] || { DNOTE="$DOMAIN answered (HTTP $LAST_ST) without a fingerprint and without a file from this build, so I can't compare it"; return 1; }
  while IFS=$'\t' read -r env url; do
    { [ -n "$url" ] && [ "$url" != "-" ]; } || continue
    read -r ust utag <<<"$(bash "$S/etag.sh" "$url")"
    case "$ust" in 2*) ;; *) continue ;; esac
    [ -n "$utag" ] || continue
    compared=1
    if [ "$DTAG" = "$utag" ]; then
      if [ -n "$btag" ] && [ "$DTAG" = "$btag" ]; then
        DNOTE="your home page is the same before and after this release, so it can't show which build $DOMAIN serves"; return 1
      fi
      return 0
    fi
  done <<EOF
$DEP_OK
EOF
  [ $compared = 1 ] && { DOMAIN_OTHER=1; DNOTE="$DOMAIN serves a different build"; return 1; }
  if [ -n "$btag" ] && [ "$DTAG" != "$btag" ]; then
    DNOTE="$DOMAIN changed after the push, but its home page doesn't load a file from this build (your host's build may differ, for example through environment variables) and the deployment's own address couldn't be compared"
  else DNOTE="your home page didn't change, and the deployment's own address couldn't be compared"; fi
  return 1
}
# Proof from every place your site is served from (see the top). Sets PROOFS and MISSING (comma-separated), the
# domain's answer (LAST_ST, DTAG), and DNOTE / DOMAIN_OTHER when the domain has no proof. "fp": a fingerprint that
# matches a new deployment counts as proof for the domain. Returns 0 when nothing is missing.
LAST_ST=""; DTAG=""; DNOTE=""; DOMAIN_OTHER=0; PROOFS=""; MISSING=""
targets_check() {
  local u h id a n=0 covered=0 body="$WT/.launch-now.html"
  PROOFS=""; MISSING=""; DNOTE=""; DOMAIN_OTHER=0
  while IFS= read -r u; do
    [ -z "$u" ] && continue
    n=$((n + 1)); bash "$S/etag.sh" "$u" "$WT/.launch-liveurl-$n.txt" >/dev/null
    if id="$(has_word_id "$WT/.launch-liveurl-$n.txt")"; then
      PROOFS="$PROOFS; $u shows this release's commit id, $id"
      h="${u#*://}"; h="${h%%/*}"; [ -n "$HOST" ] && [ "$h" = "$HOST" ] && covered=1
    else MISSING="$MISSING, $u"; fi
  done <<EOF
$LIVEURLS
EOF
  if [ -n "$DOMAIN" ]; then
    : > "$body"; read -r LAST_ST DTAG <<<"$(bash "$S/etag.sh" "$DOMAIN" "$body")"
    if [ $covered = 0 ]; then
      if id="$(page_id "$body")"; then PROOFS="$PROOFS; $DOMAIN carries this release's commit id, $id"
      elif a="$(new_asset "$body")"; then PROOFS="$PROOFS; $DOMAIN now loads $a, a file only this build has"
      elif [ "${1:-}" = fp ] && fingerprint; then PROOFS="$PROOFS; $DOMAIN has the same fingerprint as the new deployment"
      else MISSING="$MISSING, $DOMAIN"; fi
    fi
  fi
  PROOFS="${PROOFS#; }"; MISSING="${MISSING#, }"
  [ -z "$MISSING" ] && [ -n "$PROOFS" ]
}
site_proof() {   # one look for proof; LIVE ends the run
  if targets_check; then echo "LIVE: ${SHA:0:7} is live: $PROOFS ($(now))"; led LIVE "$(now)"; exit 0; fi
  return 1
}
# The time limit passed, and your site showed no proof.
site_timeout() {
  local how="${why:+ ($why, so I watched your site itself)}" hint="" what="${MISSING:-$SITE}"
  [ -n "$dfail" ] && deploy_failed
  if [ -z "$LIVEURLS" ] && { [ ! -s "$WT/.launch-assets" ] || [ ! -s "$WT/.launch-before.html" ]; }; then
    hint="To let launchcodes confirm it next time: set \"liveUrl\" to a page that shows the commit id (like /version.txt), or have your build write the commit id into your home page."
  fi
  if [ -n "$DOMAIN" ] && [ "${LAST_ST:-000}" = 000 ]; then
    echo "TIMEOUT after ${el}s: $DOMAIN didn't answer$how. Look at it yourself, and at your host's dashboard."
    led UNCONFIRMED "timeout, site didn't answer"; exit 2
  fi
  case ", $MISSING," in
    *", $DOMAIN,"*)
      if [ -s "$WT/.launch-before.html" ] && [ -s "$WT/.launch-now.html" ] && ! cmp -s "$WT/.launch-before.html" "$WT/.launch-now.html"; then
        echo "NOT_CONFIRMED after ${el}s: $DOMAIN changed after the push, but nothing on it names ${SHA:0:7} or loads a file only"
        echo "this build has, so I can't tell it's this release$how. Have a look at $DOMAIN yourself."
        [ -n "$hint" ] && echo "$hint"
        led UNCONFIRMED "site changed, no proof"; exit 5
      fi ;;
  esac
  echo "TIMEOUT after ${el}s: $what doesn't show ${SHA:0:7} yet$how. If your host is still deploying, look again in a few minutes."
  [ -n "$hint" ] && echo "$hint"
  led UNCONFIRMED "timeout, no sign of it on the site"; exit 2
}

# Can GitHub tell us about the deployments? If not, your site is the whole check.
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

# Every production deployment of the commit, one per project ("environment"), each by its newest status:
#   DEP_OK "env<TAB>its own address" · DEP_FAILED "env<TAB>reason" · DEP_GONE / DEP_BUSY "env"
# and CTX_BUSY: the commit's own statuses from a host that are still pending. (Vercel marks the commit "pending"
# while a project builds, and records the deployment only when it's done: that is how a second project still
# building shows up before it has a deployment.)
DEP_OK=""; DEP_FAILED=""; DEP_GONE=""; DEP_BUSY=""; CTX_BUSY=""
host_state() {
  local rows id env line at state url desc envs="|"
  DEP_OK=""; DEP_FAILED=""; DEP_GONE=""; DEP_BUSY=""
  rows="$(gh api "repos/$REPO/deployments?sha=$SHA&per_page=50" --jq '.[] | select((.environment // "") | test("production"; "i")) | [(.id | tostring), .environment] | @tsv' 2>/dev/null | sort -t "$(printf '\t')" -k1,1nr)"
  while IFS=$'\t' read -r id env; do
    [ -n "$id" ] || continue
    case "$envs" in *"|$env|"*) continue ;; esac            # the newest deployment of each project counts
    envs="$envs$env|"
    line="$(gh api "repos/$REPO/deployments/$id/statuses?per_page=1" --jq '.[0] // empty | [.created_at, .state, ((.environment_url // "") | if . == "" then "-" else . end), ((.description // "") | if . == "" then "-" else . end)] | @tsv' 2>/dev/null)"
    at=""; state=""; url="-"; desc="-"
    [ -n "$line" ] && IFS=$'\t' read -r at state url desc <<<"$line"
    case "$state" in
      success) DEP_OK="$DEP_OK$env"$'\t'"$url"$'\n' ;;
      failure|error) DEP_FAILED="$DEP_FAILED$env"$'\t'"$desc"$'\n' ;;
      inactive) DEP_GONE="$DEP_GONE$env"$'\n' ;;
      *) DEP_BUSY="$DEP_BUSY$env"$'\n' ;;
    esac
  done <<EOF
$rows
EOF
  CTX_BUSY="$(gh api "repos/$REPO/commits/$SHA/status" --jq '[.statuses[] | select(.state == "pending") | select(((.context // "") + " " + (.target_url // "") + " " + (.description // "")) | test("deploy|vercel|netlify|cloudflare|render|railway|fly\\.io|heroku|amplify|firebase"; "i")) | .context] | unique | .[]' 2>/dev/null)"
}
names() { printf '%s' "$1" | cut -f1 | grep . | tr '\n' ',' | sed 's/,$//; s/,/, /g'; }
build_failed() {
  local env desc says
  IFS=$'\t' read -r env desc <<<"$(printf '%s' "$DEP_FAILED" | head -1)"
  # The deployment's own status is often terse ("Deployment was blocked"); the commit's statuses say why.
  says="$(gh api "repos/$REPO/commits/$SHA/statuses" --jq '[.[] | select(.state == "failure" or .state == "error") | (.description // "") + "\t" + (.target_url // "")] | unique | .[0:3][]' 2>/dev/null)"
  echo "BUILD_FAILED: your host didn't put ${SHA:0:7} live ($desc). The previous version is still live, but $PROD now has"
  echo "the new commit."
  if [ -n "$DEP_OK" ] || [ "$(printf '%s' "$DEP_FAILED" | grep -c .)" -gt 1 ]; then
    echo "It failed in: $(names "$DEP_FAILED")."
    [ -n "$DEP_OK" ] && echo "It built in: $(names "$DEP_OK"), so that part of the release may be live already."
  fi
  if [ -n "$says" ]; then
    echo "Your host says:"; printf '%s\n' "$says" | while IFS=$'\t' read -r d u; do echo "   $d${u:+  ($u)}"; done
  fi
  if printf '%s %s' "$desc" "$says" | grep -qiE 'blocked|access|permission|not allowed|unauthori|seat|limit'; then
    echo "That is your host REFUSING the deployment (an account, team or plan setting), not a fault in your code. Fix the"
    echo "setting at your host, then redeploy from its dashboard or run /launchcodes again."
  else
    echo "Fix it and run /launchcodes again, or revert it. Your host's dashboard has the build log."
  fi
  led FAILED "$(names "$DEP_FAILED")"; exit 1
}
confirm_success() {
  local n many="" note u rest
  n="$(printf '%s' "$DEP_OK" | grep -c .)"
  [ "$n" -gt 1 ] && many=" (all $n production deployments built it: $(names "$DEP_OK"))"
  if [ -z "$SITE" ]; then
    echo "DEPLOYED: your host finished the production build of ${SHA:0:7}$many ($(now)). Your site wasn't checked: set \"domain\" in .claude/launchcodes.json to check it next time."
    led DEPLOYED "$(now)"; exit 0
  fi
  for i in 1 2 3 4 5 6; do
    if targets_check fp; then echo "LIVE: ${SHA:0:7} is live$many: $PROOFS ($(now))"; led LIVE "$(now)"; exit 0; fi
    [ "$i" -lt 6 ] || break
    [ $(( $(date +%s) - start + RETRY_SLEEP )) -le $(( TIMEOUT + 5 )) ] || break   # stay inside the caller's time limit
    sleep "$RETRY_SLEEP"
  done
  if [ "$DOMAIN_OTHER" = 1 ]; then
    echo "NOT_CONFIRMED: your host built ${SHA:0:7}, but $DOMAIN serves a different build: a newer push, an Instant Rollback (undo it in"
    echo "your host's dashboard), or the domain isn't assigned to production. Check your host's dashboard."
    led UNCONFIRMED "domain serves another build"; exit 5
  fi
  note="$DNOTE"; rest="$MISSING"
  while [ -n "$rest" ]; do
    u="${rest%%, *}"; if [ "$u" = "$rest" ]; then rest=""; else rest="${rest#*, }"; fi
    [ "$u" != "$DOMAIN" ] && note="${note:+$note; }$u doesn't show its commit id"
  done
  [ -n "$note" ] || note="your site could not be confirmed"
  echo "DEPLOYED: your host finished the production build of ${SHA:0:7}$many ($(now)), but $note. Have a look at $SITE yourself."
  led DEPLOYED "unconfirmed: ${note:-no proof}"; exit 0
}

seen=0
while :; do
  el=$(( $(date +%s) - start ))
  if [ $GH = 1 ]; then
    host_state
    [ -n "$DEP_OK$DEP_FAILED$DEP_GONE$DEP_BUSY" ] && seen=1
    [ -n "$DEP_FAILED" ] && build_failed
    if [ -n "$DEP_GONE" ]; then
      echo "NOT_CONFIRMED: a newer production deployment already replaced ${SHA:0:7} ($(names "$DEP_GONE")). Check your host's dashboard for what's live now."
      led UNCONFIRMED superseded; exit 5
    fi
    [ -n "$DEP_OK" ] && [ -z "$DEP_BUSY" ] && [ -z "$CTX_BUSY" ] && confirm_success
  fi
  # Nothing finished on GitHub yet: your site itself may already show this release, unless a project is still building.
  if [ -n "$SITE" ] && [ -z "$DEP_BUSY" ] && [ -z "$CTX_BUSY" ]; then site_proof; fi
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
      busy="$(printf '%s\n%s\n' "$DEP_BUSY" "$CTX_BUSY" | grep . | sort -u | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
      if [ -n "$busy" ]; then
        echo "TIMEOUT after ${el}s, STILL BUILDING: your host is still deploying ${SHA:0:7} ($busy)."
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
