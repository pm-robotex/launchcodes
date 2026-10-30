#!/usr/bin/env bash
# prepare.sh <repo> [commit] [--dry-run]
# Step 1 of /launchcodes. Never changes your files, your branches or the remote: it fetches, works out what would
# go live, gives this release its launch code (like 14Oct-2), and makes a CLEAN copy of exactly that commit (a git
# worktree) somewhere else, so the build and the checks see what you COMMITTED, not what is on your disk.
# (A file you forgot to `git add` makes your local build pass and the real deploy fail. The clean copy catches it.)
# It also warns when the build could change things outside its folder, because the build runs before your yes.
# Exit: 0 ready | 1 nothing to ship / not a fast-forward | 3 setup problem (nothing was created)
set -u
VERSION=0.2.1
S="$(cd "$(dirname "$0")" && pwd)"
die() { echo "$1"; exit "${2:-3}"; }
abspath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$(cd "$1" && pwd)"; else (cd "$1" && pwd); fi; }

ARG_REPO=""; ARG_COMMIT=""; DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run|dry-run) DRY=1 ;;
    *) if [ -z "$ARG_REPO" ]; then ARG_REPO="$a"; elif [ -z "$ARG_COMMIT" ]; then ARG_COMMIT="$a"; else die "usage: prepare.sh <repo> [commit] [--dry-run]"; fi ;;
  esac
done
[ -n "$ARG_REPO" ] || die "usage: prepare.sh <repo> [commit] [--dry-run]"
echo "launchcodes $VERSION"

# 0 · tools
command -v git >/dev/null 2>&1 || die "SETUP: git is not installed."
command -v node >/dev/null 2>&1 || die "SETUP: Node.js is not installed (version 18 or newer is needed)."
nv="$(node -p 'process.versions.node' 2>/dev/null)"; nmaj="${nv%%.*}"; nrest="${nv#*.}"; nmin="${nrest%%.*}"
{ [ "${nmaj:-0}" -gt 18 ] || { [ "${nmaj:-0}" -eq 18 ] && [ "${nmin:-0}" -ge 18 ]; }; } 2>/dev/null || die "SETUP: Node.js 18.18 or newer is needed (found $(node -v 2>/dev/null))."
gmaj="$(git version | sed -E 's/^[^0-9]*([0-9]+)\.([0-9]+).*/\1/')"; gmin="$(git version | sed -E 's/^[^0-9]*([0-9]+)\.([0-9]+).*/\2/')"
{ [ "$gmaj" -gt 2 ] || { [ "$gmaj" -eq 2 ] && [ "$gmin" -ge 17 ]; }; } 2>/dev/null || die "SETUP: git 2.17 or newer is needed (found $(git version))."

# 1 · the repo
top="$(git -C "$ARG_REPO" rev-parse --show-toplevel 2>/dev/null)" || die "NOT A GIT REPO: $ARG_REPO"
R="$(abspath "$top")" || die "NOT A GIT REPO: $ARG_REPO"
S="$(abspath "$S")"
g() { git -C "$R" "$@"; }
msg="$(node "$S/cfg.mjs" "$R" --check)" || die "$msg"
g remote get-url origin >/dev/null 2>&1 || die "NO REMOTE named origin: launchcodes pushes to the remote called origin (git remote -v lists yours)."
[ "$(g rev-parse --is-shallow-repository 2>/dev/null)" = true ] && die "SHALLOW CLONE: this copy of the repo has only part of its history. Run  git fetch --unshallow  and then /launchcodes again."
GD="$(g rev-parse --absolute-git-dir)"
for f in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
  [ -e "$GD/$f" ] && die "A git operation is in progress in your folder ($f). Finish or abort it first."
done
PROD="$(node "$S/cfg.mjs" "$R" prodBranch "")" || die "$PROD"
APPDIR="$(node "$S/cfg.mjs" "$R" appDir "")" || die "$APPDIR"

echo "Fetching origin..."
g fetch origin -q || die "FETCH_FAILED: git could not reach origin. Check your network, and that  git fetch origin  works in this folder."
[ -z "$PROD" ] && PROD="$(g symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
[ -z "$PROD" ] && PROD=main
BASE="$(g rev-parse --verify -q "refs/remotes/origin/$PROD^{commit}")" || die "NO BRANCH $PROD on origin: set \"prodBranch\" in .claude/launchcodes.json to the branch your host deploys."
T="$(g rev-parse --verify -q "${ARG_COMMIT:-HEAD}^{commit}")" || die "UNKNOWN COMMIT: ${ARG_COMMIT:-HEAD}"

[ "$T" = "$BASE" ] && die "NOTHING_TO_SHIP: $PROD on origin already is ${T:0:7}. (Did you commit your work?)" 1
g merge-base --is-ancestor "$T" "$BASE" && die "NOTHING_TO_SHIP: ${T:0:7} is already part of $PROD on origin." 1
RC="$(node "$S/cfg.mjs" "$R" releaseCommit "")" || die "$RC"
# With "releaseCommit", every release lands as a merge commit named after it, which your branch doesn't have. That
# is fine as long as those release commits are ALL that $PROD has beyond your branch, and they add no files of
# their own: then $PROD's files are exactly the ones your branch started from.
rel_only() {
  local mb; mb="$(g merge-base "$BASE" "$T" 2>/dev/null)" || return 1
  [ "$(g rev-parse "$BASE^{tree}")" = "$(g rev-parse "$mb^{tree}")" ] || return 1
  ! g log --first-parent --format='%p%x09%s' "$mb..$BASE" | grep -vE '^[0-9a-f]+ [0-9a-f]+	Ship [0-9]{2}[A-Za-z]{3}-[0-9]+ ' | grep -q .
}
if ! g merge-base --is-ancestor "$BASE" "$T" && ! { [ "$RC" = true ] && rel_only; }; then
  echo "NOT_FAST_FORWARD: $PROD on origin has commits that ${T:0:7} doesn't have:"
  g log --format='   %h %s' "$T..$BASE" | head -10
  echo "Your release has to sit on top of what's live. Bring those commits into your branch the way your team does"
  echo "(merge, or rebase a branch only you use: never rewrite a branch other people share), or release a commit"
  echo "that is built on top of $PROD with  /launchcodes <commit> . Then run /launchcodes again."
  exit 1
fi

# 2 · what would go live
echo; echo "== $(g rev-list --count "$BASE..$T") commit(s) would go live on $PROD (oldest first)"
g log --reverse --format='   %h %s' "$BASE..$T"
echo; echo "== Files that would change"
g -c core.quotePath=false diff --name-status --no-renames "$BASE" "$T" | sed 's/^/   /'
mod=$(g status --porcelain --untracked-files=no | grep -c .)
unt=$(g status --porcelain | grep -c '^??')
if [ "$mod" -gt 0 ] || [ "$unt" -gt 0 ]; then
  echo; echo "== NOT part of this release: $mod changed and $unt new file(s) in your folder that aren't committed."
  echo "   Only committed work goes live. If any of them is needed, commit it and run /launchcodes again."
fi
if [ -n "$ARG_COMMIT" ]; then
  head="$(g rev-parse HEAD)"
  if [ "$head" != "$T" ] && g merge-base --is-ancestor "$T" "$head"; then
    echo; echo "== NEWER: $(g rev-list --count "$T..$head") commit(s) on your branch come after ${T:0:7} and are NOT in this release."
  fi
fi

# 3 · can the build change things outside its folder? It runs before the owner's yes.
cmds="$(node "$S/cfg.mjs" "$R" installCommand ""; echo; node "$S/cfg.mjs" "$R" buildCommand "")"
pkg="$(g show "$T:${APPDIR:+$APPDIR/}package.json" 2>/dev/null)"
effects="$(printf '%s' "$pkg" | node -e '
  let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
    let scripts = {}; try { scripts = JSON.parse(s).scripts || {}; } catch {}
    const extra = process.argv[1].split("\n").map((c, i) => [i ? "buildCommand" : "installCommand", c]).filter(([, c]) => c);
    const risky = /migrat|deploy|upload|seed|db push|db reset|supabase (db|functions)|prisma (migrate|db)|drizzle-kit (push|migrate)|knex migrate|sequelize db|sentry-cli|firebase deploy|wrangler (deploy|publish)|curl |wget /i;
    for (const [k, v] of [...Object.entries(scripts).filter(([k]) => /^(pre|post)?(install|build|prepare)$/.test(k)), ...extra])
      if (risky.test(String(v))) console.log(`   ${k}: ${v}`);
  });' "$cmds")"
migs="$(g -c core.quotePath=false diff --name-status --diff-filter=AM --no-renames "$BASE" "$T" | grep -E '(^|/)(supabase/migrations|prisma/migrations|migrations|db/migrate)/' \
  | awk -F'\t' '{ print $2 ($1 == "M" ? "   <- EDITED: this file was already in an earlier release; production may need the change applied again" : "") }')"
nmigs="$(printf '%s' "$migs" | grep -c .)"; migs="$(printf '%s\n' "$migs" | head -40)"
if [ -n "$effects" ]; then
  echo; echo "== BUILD MAY CHANGE THINGS: these run in the build step, BEFORE your yes:"; echo "$effects"
  echo "   If they reach a real database or service, ask before building (or point them at test settings)."
fi
if [ "$nmigs" -gt 0 ]; then
  echo; echo "== MIGRATION FILES in this release: $nmigs (launchcodes never applies them; all must be on production first):"
  echo "$migs" | sed 's/^/   /'; [ "$nmigs" -gt 40 ] && echo "   ... and $((nmigs - 40)) more"
fi
# Supabase edge functions run on Supabase, not on your host: pushing the branch doesn't deploy them.
fns="$(g -c core.quotePath=false diff --name-only --no-renames "$BASE" "$T" | sed -nE 's#^(.*/)?supabase/functions/([^/]+)/.*#\2#p' | sort -u | tr '\n' ' ' | sed 's/ $//')"
if [ -n "$fns" ]; then
  echo; echo "== EDGE FUNCTIONS changed in this release: pushing does NOT deploy them (they run on Supabase, not your host):"
  for f in $fns; do if [ "$f" = _shared ]; then echo "   _shared (code every function that imports it uses)"; else echo "   $f"; fi; done
fi
# First run: no settings file. The two settings that complete the checks can't be guessed safely, so they are asked.
if [ ! -f "$R/.claude/launchcodes.json" ]; then
  echo; echo "== FIRST RUN: no .claude/launchcodes.json yet. Claude can create it from your answers (setup.sh), so that:"
  echo "   - the live check confirms your domain serves each release (\"domain\")"
  g grep -q '"@supabase/supabase-js"' "$T" -- '*package.json' 2>/dev/null \
    && echo "   - the database check knows your PRODUCTION Supabase project without asking each time (\"supabaseProjectRef\")"
fi

# 4 · the launch ledger (inside .git: never committed, never pushed), other releases, leftovers
CD="$(cd "$R" && cd "$(git rev-parse --git-common-dir)" && pwd)" && CD="$(abspath "$CD")" || die "SETUP: can't find the .git folder of $R"
L="$CD/launchcodes"; LOG="$L/ships.log"
mkdir -p "$L/codes" || die "SETUP: can't write $L"
lg="$(node "$S/ledger.mjs" "$LOG")"; [ -n "$lg" ] && { echo; echo "$lg"; }
left="$(g worktree list --porcelain | sed -n 's#^worktree \(.*/launch-[^/]*\)$#\1#p' | while IFS= read -r w; do [ -f "$w/.launch-state" ] && echo "   $w"; done)"
[ -n "$left" ] && { echo; echo "== Clean copies from earlier runs still on disk (remove one with cleanup.sh when you're sure no chat is using it):"; echo "$left"; }

day="$(date +%Y-%m-%d)"; dd="$(LC_ALL=C date +%d%b)"; CODE=""
for i in $(seq 1 99); do mkdir "$L/codes/$day-$i" 2>/dev/null && { CODE="$dd-$i"; break; }; done
[ -n "$CODE" ] || die "SETUP: no free launch code left for today in $L/codes"

# 5 · the clean copy: launch-<repo>-<6 characters unique to this repo>-<code>-<4 random characters>
name="$(basename "$R" | tr -c 'A-Za-z0-9\n' '-' | cut -c1-24)"
rid="$(printf '%s' "$CD" | git hash-object --stdin | cut -c1-6)"
wd="$(node "$S/cfg.mjs" "$R" workDir "")" || die "$wd"
if [ -n "$wd" ]; then
  mkdir -p "$wd" 2>/dev/null; place="$wd"
else
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)   # a short path at the top of the drive: long paths break Windows checkouts
      place="${R%%/*}"; case "$R" in //*) place="" ;; esac
      if [ -z "$place" ] || ! { mkdir "$place/.launchcodes-probe-$$" 2>/dev/null && rmdir "$place/.launchcodes-probe-$$"; }; then
        place="$(cygpath -m "${LOCALAPPDATA:-$HOME/AppData/Local}")/launchcodes"; mkdir -p "$place"
      fi ;;
    Darwin) place="${TMPDIR:-/tmp}"; place="${place%/}" ;;
    *) place="${XDG_CACHE_HOME:-$HOME/.cache}/launchcodes"; mkdir -p "$place" ;;
  esac
fi
# 4 random characters at the end: launch codes start again every day, and the push command names this folder, so a
# "don't ask again" saved for one launch can never approve another one.
nonce="$(od -An -N2 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"; [ -n "$nonce" ] || nonce="$(printf '%04x' "$RANDOM")"
WT="$place/launch-$name-$rid-$CODE-$nonce"
[ -e "$WT" ] && die "EXISTS: $WT is already there. If another chat is using it, wait for that release to finish; if not, remove it with cleanup.sh and run /launchcodes again."
if ! out="$(g -c core.longpaths=true worktree add --detach "$WT" "$T" 2>&1)"; then
  [ -e "$WT" ] && g -c core.longpaths=true worktree remove --force "$WT" >/dev/null 2>&1
  die "WORKTREE_FAILED: git could not create the clean copy at $WT: $out"
fi
TREE="$(g rev-parse "$T^{tree}")"

# 6 · can the live check run after the push?
DOMAIN="$(node "$S/cfg.mjs" "$R" domain "")"
case "$(g config --get remote.origin.url)" in
  *github.com[:/]*)
    if ! command -v gh >/dev/null 2>&1; then LIVE="no: the GitHub CLI (gh) isn't installed, so after the push you check your host's dashboard yourself"
    elif ! gh auth status >/dev/null 2>&1; then LIVE="no: gh isn't logged in (run  gh auth login ), so after the push you check your host's dashboard yourself"
    elif [ -n "$DOMAIN" ]; then LIVE="yes: waits for your host's production deployment, then checks that $DOMAIN serves it"
    else LIVE="partly: waits for your host's production deployment, but doesn't check your domain (set \"domain\" in .claude/launchcodes.json)"; fi ;;
  *) LIVE="no: origin isn't on GitHub, so after the push you check your host's dashboard yourself" ;;
esac

# 7 · commits already on $PROD that your host never put live (a failed or blocked build): they go live with this
# release, so the plan must name them. Your host's last successful production deployment, as GitHub records it.
UNDEP=0; LIVE_SHA=""
case "$LIVE" in yes*|partly*)
  REPO="$(g config --get remote.origin.url | sed -nE 's#^.*github\.com[:/]+([^/]+/[^/]+)$#\1#p' | sed 's#\.git$##')"
  for line in $(gh api "repos/$REPO/deployments?per_page=10" --jq '.[] | select((.environment // "") | test("production"; "i")) | "\(.id):\(.sha)"' 2>/dev/null); do
    st="$(gh api "repos/$REPO/deployments/${line%%:*}/statuses?per_page=1" --jq '.[0].state // empty' 2>/dev/null)"
    [ "$st" = success ] && { LIVE_SHA="${line#*:}"; break; }
  done
  if [ -n "$LIVE_SHA" ] && [ "$LIVE_SHA" != "$BASE" ] && g cat-file -e "$LIVE_SHA^{commit}" 2>/dev/null; then
    if g merge-base --is-ancestor "$LIVE_SHA" "$BASE" 2>/dev/null; then
      UNDEP="$(g rev-list --count --no-merges "$LIVE_SHA..$BASE")"
      if [ "$UNDEP" -gt 0 ]; then
        echo; echo "== ALSO GOING LIVE: $UNDEP commit(s) are already on $PROD, but your host never put them live (its last"
        echo "   production build is ${LIVE_SHA:0:7}). Your host builds the newest commit, so they go live with this release:"
        g log --no-merges --format='   %h %s' "$LIVE_SHA..$BASE" | head -10
      fi
    else
      echo; echo "== YOUR HOST'S LAST PRODUCTION BUILD (${LIVE_SHA:0:7}) isn't part of $PROD's history (a rollback?). Check its dashboard."
    fi
  fi ;;
esac

{ printf 'VERSION=%q\n' "$VERSION"; printf 'CODE=%q\n' "$CODE"; printf 'R=%q\n' "$R"; printf 'S=%q\n' "$S"; printf 'WT=%q\n' "$WT"
  printf 'PROD=%q\n' "$PROD"; printf 'BASE=%q\n' "$BASE"; printf 'T=%q\n' "$T"; printf 'TREE=%q\n' "$TREE"
  printf 'LOG=%q\n' "$LOG"; printf 'DRY_RUN=%q\n' "$DRY"; printf 'LIVE_CHECK=%q\n' "$LIVE"
  printf 'RELEASE_COMMIT=%q\n' "$RC"; printf 'EDGE_FNS=%q\n' "$fns"; printf 'UNDEPLOYED=%q\n' "$UNDEP $LIVE_SHA"; } > "$WT/.launch-state"
note="${T:0:7}"; [ "$DRY" = 1 ] && note="$note dry-run"
printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M %Z')" "$CODE" PREPARED "$note" >> "$LOG"

echo; echo "LAUNCH CODE: $CODE"
echo "WT=$WT"
echo "LIVE CHECK: $LIVE"
[ "$DRY" = 1 ] && echo "DRY RUN: every check runs and the plan is shown; nothing will be pushed."
echo "NEXT: build"
