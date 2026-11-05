#!/usr/bin/env bash
# prepare.sh <repo> [commit] [--dry-run]
# prepare.sh <repo> --pick <commit> [<commit> ...] [--dry-run]
# Step 1 of /launchcodes. Never changes your files, your branches or the remote: it fetches, works out what would
# go live, gives this release its launch code (like 14Oct-2), and makes a CLEAN copy of exactly that (a git
# worktree) somewhere else, so the build and the checks see what you COMMITTED, not what is on your disk.
# (A file you forgot to `git add` makes your local build pass and the real deploy fail. The clean copy catches it.)
# --pick is for a branch that production takes only some commits from (staging, a sandbox). The clean copy starts
# from what is live and gets just the commits you name, oldest first, with `git cherry-pick -x`. The build and the
# checks then test that exact combination, so a pick that needs a commit you left behind fails here, before your
# yes. The new commits exist only in the clean copy until the push; your branches stay as they are.
# It also checks that the push will stop for your yes (gate.mjs), and warns when the build could change things
# outside its folder, because the build runs before your yes.
# Exit: 0 ready | 1 nothing to ship, not a fast-forward, or a pick that can't be applied | 3 setup problem
# (except for a pick that can't be applied, which removes its copy again, nothing is created on any non-zero exit)
set -u
VERSION=0.4.0
S="$(cd "$(dirname "$0")" && pwd)"
die() { echo "$1"; exit "${2:-3}"; }
abspath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$(cd "$1" && pwd)"; else (cd "$1" && pwd); fi; }

USAGE="usage: prepare.sh <repo> [commit] [--dry-run]   or   prepare.sh <repo> --pick <commit> [<commit> ...] [--dry-run]"
ARG_REPO=""; ARG_COMMIT=""; DRY=0; PICK=0; PICKS_IN=""
for a in "$@"; do
  case "$a" in
    --dry-run|dry-run) DRY=1 ;;
    --pick) PICK=1 ;;
    -*) die "$USAGE" ;;
    *) if [ -z "$ARG_REPO" ]; then ARG_REPO="$a"
       elif [ $PICK = 1 ]; then PICKS_IN="$PICKS_IN $a"
       elif [ -z "$ARG_COMMIT" ]; then ARG_COMMIT="$a"
       else die "$USAGE"; fi ;;
  esac
done
[ -n "$ARG_REPO" ] || die "$USAGE"
if [ $PICK = 1 ] && { [ -z "$PICKS_IN" ] || [ -n "$ARG_COMMIT" ]; }; then die "$USAGE"; fi
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
RC="$(node "$S/cfg.mjs" "$R" releaseCommit "")" || die "$RC"
MIGMODE="$(node "$S/cfg.mjs" "$R" migrations manual)" || die "$MIGMODE"

# Will the push stop for the owner's yes? Without that, the plan would be the only stop. A dry run never pushes, so
# there it is only reported.
gate="$(node "$S/gate.mjs" "$R" "$S")"; grc=$?
if [ $grc -ne 0 ] && [ "$DRY" != 1 ]; then
  echo "$gate"; echo "Nothing was created. Once that is fixed, run /launchcodes again."; exit 3
fi
GATE="${gate%%:*}"

echo "Fetching origin..."
g fetch origin -q || die "FETCH_FAILED: git could not reach origin. Check your network, and that  git fetch origin  works in this folder."
[ -z "$PROD" ] && PROD="$(g symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
[ -z "$PROD" ] && PROD=main
BASE="$(g rev-parse --verify -q "refs/remotes/origin/$PROD^{commit}")" || die "NO BRANCH $PROD on origin: set \"prodBranch\" in .claude/launchcodes.json to the branch your host deploys."
[ $grc -ne 0 ] && { echo; echo "== APPROVAL GATE (a dry run, so it doesn't stop this one):"; echo "$gate" | sed 's/^/   /'; }

ORDER=""; DEPS=""; T=""
if [ $PICK = 0 ]; then
  T="$(g rev-parse --verify -q "${ARG_COMMIT:-HEAD}^{commit}")" || die "UNKNOWN COMMIT: ${ARG_COMMIT:-HEAD}"
  [ "$T" = "$BASE" ] && die "NOTHING_TO_SHIP: $PROD on origin already is ${T:0:7}. (Did you commit your work?)" 1
  g merge-base --is-ancestor "$T" "$BASE" && die "NOTHING_TO_SHIP: ${T:0:7} is already part of $PROD on origin." 1
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
    echo "(merge, or rebase a branch only you use: never rewrite a branch other people share), and run /launchcodes again."
    echo "Or release just the commits you want from this branch:  /launchcodes pick <commit> [<commit> ...]  applies them"
    echo "on top of $PROD in the clean copy and tests that combination."
    exit 1
  fi
else
  # "The same change is already live" is decided like `git cherry` does, by patch id (a fingerprint of the diff, so a
  # cherry-picked copy matches its original). The commits on $PROD a pick doesn't have are fingerprinted once per
  # branch point and reused, and on the pick's side only the few commits that matter, so a staging branch hundreds
  # of commits ahead stays quick.
  TMPD="$(mktemp -d 2>/dev/null)" || TMPD="${TMPDIR:-/tmp}/launchcodes-$$"; mkdir -p "$TMPD"; trap 'rm -rf "$TMPD"' EXIT
  up_ids() {     # the file listing the patch ids of $PROD's commits that $1 doesn't have
    local mbs f
    mbs="$(g merge-base --all "$BASE" "$1" 2>/dev/null | sort | tr '\n' ' ')"
    f="$TMPD/up-$(printf '%s' "$mbs" | git hash-object --stdin)"
    if [ ! -f "$f" ]; then
      if [ -n "$mbs" ]; then g log -p --no-merges --no-renames --no-color "$BASE" --not $mbs | git patch-id --stable | cut -d' ' -f1 | sort -u > "$f"
      else : > "$f"; fi
    fi
    echo "$f"
  }
  pid() { g show --no-renames --no-color "$1" | git patch-id --stable | cut -d' ' -f1; }
  live_by_content() { local p; p="$(pid "$1")"; [ -n "$p" ] && grep -qxF -- "$p" "$(up_ids "$1")"; }
  # Each pick must be one ordinary commit (not a merge) that isn't live yet, as itself or as the same change.
  PICKS=""; skipped=""
  for p in $PICKS_IN; do
    sha="$(g rev-parse --verify -q "$p^{commit}")" || die "UNKNOWN COMMIT: $p" 1
    case " $PICKS " in *" $sha "*) continue ;; esac
    np=$(( $(g rev-list --parents -n1 "$sha" | wc -w) - 1 ))
    [ "$np" -gt 1 ] && die "PICK_MERGE: ${sha:0:7} is a merge commit. Pick the commits it brought in instead." 1
    [ "$np" -lt 1 ] && die "PICK_ROOT: ${sha:0:7} is the very first commit of its history, so it can't be applied on top of $PROD." 1
    subj="$(g log -1 --format=%s "$sha" | cut -c1-80)"
    if g merge-base --is-ancestor "$sha" "$BASE"; then skipped="$skipped   ${sha:0:7} $subj   <- already part of $PROD"$'\n'; continue; fi
    if live_by_content "$sha"; then skipped="$skipped   ${sha:0:7} $subj   <- the same change is already live"$'\n'; continue; fi
    PICKS="$PICKS $sha"
  done
  [ -n "$skipped" ] && { echo; echo "== LEFT OUT, already live:"; printf '%s' "$skipped"; }
  [ -n "$PICKS" ] || die "NOTHING_TO_SHIP: everything you picked is already live on $PROD." 1
  # Oldest first, in the order of their own history: a commit always lands after the ones it builds on.
  ORDER="$(g rev-list --reverse --topo-order $PICKS --not "$BASE" | awk -v p="$PICKS" 'BEGIN { n = split(p, a, " "); for (i = 1; i <= n; i++) w[a[i]] = 1 } ($0 in w)')"
  # Earlier commits on a pick's own history that change the same files and aren't live (not even as the same
  # change): the pick may rely on them. The build catches some of that; this names the rest.
  for sha in $ORDER; do
    files="$(g -c core.quotePath=false diff-tree --no-commit-id --name-only -r --no-renames "$sha")"
    [ -n "$files" ] || continue
    up="$(up_ids "$sha")"
    for c in $(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 git -C "$R" rev-list "$sha^" --not "$BASE" -- 2>/dev/null | head -200); do
      case " $PICKS $DEPS " in *" $c "*) continue ;; esac
      p="$(pid "$c")"; [ -n "$p" ] && grep -qxF -- "$p" "$up" && continue     # the same change is live
      DEPS="$DEPS $c"
    done
  done
  if [ -n "$DEPS" ]; then
    nd=$(printf '%s\n' $DEPS | grep -c .)
    echo; echo "== EARLIER CHANGES NOT PICKED: $nd commit(s) before your picks change the same files and aren't live."
    echo "   Your picks may rely on them (the build catches only some of that):"
    for c in $DEPS; do echo "   ${c:0:7} $(g log -1 --format=%s "$c" | cut -c1-90)"; done | head -10
    [ "$nd" -gt 10 ] && echo "   ... and $((nd - 10)) more"
  fi
fi

# 2 · what would go live, and what it needs (in pick mode this runs once the picks are applied)
describe() {
  echo; echo "== $(g rev-list --count "$BASE..$T") commit(s) would go live on $PROD (oldest first)"
  if [ $PICK = 1 ]; then
    for c in $(g rev-list --reverse "$BASE..$T"); do
      o="$(g log -1 --format=%B "$c" | sed -n 's/^(cherry picked from commit \([0-9a-f]*\))$/\1/p' | tail -1)"
      echo "   $(g log -1 --format='%h %s' "$c")${o:+   (picked from ${o:0:7})}"
    done
  else
    g log --reverse --format='   %h %s' "$BASE..$T"
  fi
  echo; echo "== Files that would change"
  g -c core.quotePath=false diff --name-status --no-renames "$BASE" "$T" | sed 's/^/   /'
  mod=$(g status --porcelain --untracked-files=no | grep -c .)
  unt=$(g status --porcelain | grep -c '^??')
  if [ "$mod" -gt 0 ] || [ "$unt" -gt 0 ]; then
    echo; echo "== NOT part of this release: $mod changed and $unt new file(s) in your folder that aren't committed."
    echo "   Only committed work goes live. If any of them is needed, commit it and run /launchcodes again."
  fi
  if [ $PICK = 0 ] && [ -n "$ARG_COMMIT" ]; then
    head="$(g rev-parse HEAD)"
    if [ "$head" != "$T" ] && g merge-base --is-ancestor "$T" "$head"; then
      echo; echo "== NEWER: $(g rev-list --count "$T..$head") commit(s) on your branch come after ${T:0:7} and are NOT in this release."
    fi
  fi

  # Can the build change things outside its folder? It runs before the owner's yes.
  cmds="$(node "$S/cfg.mjs" "$R" installCommand ""; echo; node "$S/cfg.mjs" "$R" buildCommand ""; echo; node "$S/cfg.mjs" "$R" checks "")"
  pkg="$(g show "$T:${APPDIR:+$APPDIR/}package.json" 2>/dev/null)"
  effects="$(printf '%s' "$pkg" | node -e '
    let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
      let scripts = {}; try { scripts = JSON.parse(s).scripts || {}; } catch {}
      const extra = process.argv[1].split("\n").map((c, i) => [["installCommand", "buildCommand"][i] || "your check", c]).filter(([, c]) => c);
      const risky = /migrat|deploy|upload|seed|db push|db reset|supabase (db|functions)|prisma (migrate|db)|drizzle-kit (push|migrate)|knex migrate|sequelize db|sentry-cli|firebase deploy|wrangler (deploy|publish)|curl |wget /i;
      for (const [k, v] of [...Object.entries(scripts).filter(([k]) => /^(pre|post)?(install|build|prepare)$/.test(k)), ...extra])
        if (risky.test(String(v))) console.log(`   ${k}: ${v}`);
    });' "$cmds")"
  if [ -n "$effects" ]; then
    echo; echo "== BUILD MAY CHANGE THINGS: these run in the build or check step, BEFORE your yes:"; echo "$effects"
    echo "   If they reach a real database or service, ask before building (or point them at test settings)."
    [ "$MIGMODE" = deploy ] && echo "   Your deploy applies migrations: if your build script runs them, set \"buildCommand\" to the build without that step."
  fi

  # Migration files. "migrations": "manual" (the default): someone applies them before the push. "deploy": the host's
  # build applies them when the push lands. Either way the version that is live meets the new schema for a while.
  migfiles="$(g -c core.quotePath=false diff --name-status --diff-filter=AM --no-renames "$BASE" "$T" | grep -E '(^|/)(supabase/migrations|prisma/migrations|migrations|db/migrate)/')"
  edited="this file was already in an earlier release; production may need the change applied again"
  [ "$MIGMODE" = deploy ] && edited="it already ran on production, and many migration tools (Prisma among them) refuse an edited migration, which fails the deploy"
  migs="$(printf '%s\n' "$migfiles" | awk -F'\t' -v e="$edited" 'NF { print $2 ($1 == "M" ? "   <- EDITED: " e : "") }')"
  NMIGS="$(printf '%s' "$migs" | grep -c .)"; NRISKY=0
  if [ "$NMIGS" -gt 0 ]; then
    if [ "$MIGMODE" = deploy ]; then
      echo; echo "== MIGRATION FILES in this release: $NMIGS. Your deploy applies them when the push lands (\"migrations\": \"deploy\"):"
    else
      echo; echo "== MIGRATION FILES in this release: $NMIGS (launchcodes never applies them; all must be on production first):"
    fi
    printf '%s\n' "$migs" | head -40 | sed 's/^/   /'; [ "$NMIGS" -gt 40 ] && echo "   ... and $((NMIGS - 40)) more"
    risky="$(printf '%s\n' "$migfiles" | cut -f2 | tr '\n' '\0' | xargs -0 git -C "$R" -c core.quotePath=false diff --no-renames -U0 "$BASE" "$T" -- 2>/dev/null | node "$S/migration_risks.mjs")"
    NRISKY="$(printf '%s' "$risky" | grep -c .)"
    if [ "$NRISKY" -gt 0 ]; then
      if [ "$MIGMODE" = deploy ]; then
        echo; echo "== RISKY MIGRATION STATEMENTS: $NRISKY. They run by themselves during the deploy, while the previous version is still live:"
      else
        echo; echo "== RISKY MIGRATION STATEMENTS: $NRISKY. Applied before the push, they hit the version that is live now (some belong after the push):"
      fi
      printf '%s\n' "$risky" | head -20 | sed 's/^/   /'; [ "$NRISKY" -gt 20 ] && echo "   ... and $((NRISKY - 20)) more"
    fi
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
}
[ $PICK = 0 ] && describe

# 4 · the launch ledger (inside .git: never committed, never pushed), other releases, leftovers
CD="$(cd "$R" && cd "$(git rev-parse --git-common-dir)" && pwd)" && CD="$(abspath "$CD")" || die "SETUP: can't find the .git folder of $R"
L="$CD/launchcodes"; LOG="$L/ships.log"
mkdir -p "$L/codes" || die "SETUP: can't write $L"
lg="$(node "$S/ledger.mjs" "$LOG")"; [ -n "$lg" ] && { echo; echo "$lg"; }
PKEY=""; [ $PICK = 1 ] && PKEY="$(printf '%s\n' $ORDER | sort | tr '\n' ',')"
left="$(g worktree list --porcelain | sed -n 's#^worktree \(.*/launch-[^/]*\)$#\1#p' | while IFS= read -r w; do
  [ -f "$w/.launch-state" ] || continue
  c="$(sed -n 's/^CODE=//p' "$w/.launch-state" | head -1)"; t="$(sed -n 's/^T=//p' "$w/.launch-state" | head -1)"
  k="$(sed -n 's/^PICKS_KEY=//p' "$w/.launch-state" | head -1)"; same=""
  if ! grep -q '^PUSHED=' "$w/.launch-state"; then
    if [ $PICK = 0 ] && [ "$t" = "$T" ]; then same="   <- THE SAME COMMIT as this release: another chat may be launching it now"
    elif [ $PICK = 1 ] && [ -n "$k" ] && [ "$k" = "$PKEY" ]; then same="   <- THE SAME PICKS as this release: another chat may be launching them now"; fi
  fi
  echo "   $w  ($c)$same"
done)"
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
start="$T"; [ $PICK = 1 ] && start="$BASE"
if ! out="$(g -c core.longpaths=true worktree add --detach "$WT" "$start" 2>&1)"; then
  [ -e "$WT" ] && g -c core.longpaths=true worktree remove --force "$WT" >/dev/null 2>&1
  die "WORKTREE_FAILED: git could not create the clean copy at $WT: $out"
fi
if [ $PICK = 1 ]; then
  # The picks, applied in the clean copy only. A pick that doesn't apply removes the copy again: nothing is left.
  out="$(git -C "$WT" -c core.longpaths=true cherry-pick -x $ORDER 2>&1)"; prc=$?
  if [ $prc -ne 0 ]; then
    cur="$(git -C "$WT" rev-parse -q --verify CHERRY_PICK_HEAD 2>/dev/null)"
    conf="$(git -C "$WT" -c core.quotePath=false diff --name-only --diff-filter=U 2>/dev/null | head -6 | tr '\n' ' ' | sed 's/ $//')"
    git -C "$WT" cherry-pick --abort >/dev/null 2>&1
    g -c core.longpaths=true worktree remove --force "$WT" >/dev/null 2>&1; g worktree prune
    if printf '%s' "$out" | grep -qiE 'tell me who you are|identity unknown'; then
      die "SETUP: git needs your name and email to make the picked commits (git config user.name / user.email). Nothing was created."
    elif [ -n "$cur" ] && [ -n "$conf" ]; then
      echo "PICK_CONFLICT: ${cur:0:7} $(g log -1 --format=%s "$cur" | cut -c1-80) doesn't apply on top of $PROD: it conflicts in"
      echo "$conf. It probably needs an earlier commit you didn't pick (see EARLIER CHANGES NOT PICKED above, if any), or"
      echo "$PROD changed the same lines. Nothing was created."; exit 1
    elif [ -n "$cur" ]; then
      die "PICK_EMPTY: ${cur:0:7} $(g log -1 --format=%s "$cur" | cut -c1-80) changes nothing on top of $PROD: its change is already there. Leave it out. Nothing was created." 1
    else
      die "PICK_FAILED: git couldn't apply your picks: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')Nothing was created."
    fi
  fi
  T="$(git -C "$WT" rev-parse HEAD)"
  printf '%s\n' $DEPS > "$WT/.launch-pick-deps"
  describe
fi
TREE="$(g rev-parse "$T^{tree}")"

# 6 · can the live check run after the push?
# Two ways to see it: your host's deployments as GitHub records them (needs gh), or your site itself ("domain",
# "liveUrl"), which works with any host and any git server.
DOMAIN="$(node "$S/cfg.mjs" "$R" domain "")"; LIVEURL="$(node "$S/cfg.mjs" "$R" liveUrl "" | head -1)"
GHOK=0; why=""
case "$(g config --get remote.origin.url)" in
  *github.com[:/]*)
    if ! command -v gh >/dev/null 2>&1; then why="the GitHub CLI (gh) isn't installed"
    elif ! gh auth status >/dev/null 2>&1; then why="gh isn't logged in (run  gh auth login )"
    else GHOK=1; fi ;;
  *) why="origin isn't on GitHub" ;;
esac
where="${DOMAIN:-$LIVEURL}"
if [ $GHOK = 1 ] && [ -n "$where" ]; then LIVE="yes: waits until $where serves this release (it follows every production deployment your host reports on GitHub, and watches $where itself)"
elif [ $GHOK = 1 ]; then LIVE="partly: waits for your host's production deployments, but doesn't check your site (set \"domain\" in .claude/launchcodes.json)"
elif [ -n "$where" ]; then LIVE="yes: watches $where directly until it serves this release ($why, so your host's deployments can't be seen)"
else LIVE="no: $why, so after the push you check your site yourself (set \"domain\" and launchcodes watches it for you)"; fi

# 7 · commits already on $PROD that your host never put live (a failed or blocked build): they go live with this
# release, so the plan must name them. Your host's last successful production deployment, as GitHub records it.
UNDEP=0; LIVE_SHA=""
case "$GHOK" in 1)
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

PICKS_V="$(printf '%s\n' $ORDER | tr '\n' ',' | sed 's/,$//')"; DEPS_N="$(printf '%s\n' $DEPS | grep -c .)"
{ printf 'VERSION=%q\n' "$VERSION"; printf 'CODE=%q\n' "$CODE"; printf 'R=%q\n' "$R"; printf 'S=%q\n' "$S"; printf 'WT=%q\n' "$WT"
  printf 'PROD=%q\n' "$PROD"; printf 'BASE=%q\n' "$BASE"; printf 'T=%q\n' "$T"; printf 'TREE=%q\n' "$TREE"
  printf 'LOG=%q\n' "$LOG"; printf 'DRY_RUN=%q\n' "$DRY"; printf 'LIVE_CHECK=%q\n' "$LIVE"; printf 'GATE=%q\n' "$GATE"
  printf 'RELEASE_COMMIT=%q\n' "$RC"; printf 'EDGE_FNS=%q\n' "$fns"; printf 'UNDEPLOYED=%q\n' "$UNDEP $LIVE_SHA"
  printf 'PICKS=%q\n' "$PICKS_V"; printf 'PICKS_KEY=%q\n' "$PKEY"; printf 'PICK_DEPS=%q\n' "$DEPS_N"
  printf 'MIG_MODE=%q\n' "$MIGMODE"; printf 'MIG_COUNT=%q\n' "$NMIGS"; printf 'MIG_RISKY=%q\n' "$NRISKY"; } > "$WT/.launch-state"
note="${T:0:7}"; [ $PICK = 1 ] && note="$note picked"; [ "$DRY" = 1 ] && note="$note dry-run"
printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M %Z')" "$CODE" PREPARED "$note" >> "$LOG"

echo; echo "LAUNCH CODE: $CODE"
echo "WT=$WT"
[ $PICK = 1 ] && echo "PICKED: $(printf '%s\n' $ORDER | grep -c .) commit(s) applied on top of $PROD in the clean copy (your branches are unchanged)."
echo "LIVE CHECK: $LIVE"
[ "$DRY" = 1 ] && echo "DRY RUN: every check runs and the plan is shown; nothing will be pushed."
echo "NEXT: build"
