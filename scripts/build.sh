#!/usr/bin/env bash
# build.sh <WT>
# Step 2. Installs dependencies from your lockfile and runs your build INSIDE the clean copy. Records the built
# tree only when both succeed; push.sh refuses to push anything else. Exit codes are read directly, never through
# a pipe (`npm run build | tail` reports tail's exit code, so a failed build looks green).
# Your install and build run BEFORE you say yes, so they must not change anything outside their folder: no
# migrations, uploads or deploys. Launch only code you trust: the build runs it.
# The clean copy has only committed files. "buildEnvFiles" copies files that git IGNORES (like .env.local) from your
# folder into the clean copy for the build. They are never pushed: the push sends the commit, not the folder.
# Exit: 0 BUILD_PASSED, or BUILD_SKIPPED when there is nothing to build | 1 BUILD_FAILED | 3 setup problem
set -u
WT="${1:?usage: build.sh <WT>}"
[ -f "$WT/.launch-state" ] || { echo "NO STATE in $WT: run prepare.sh first"; exit 3; }
. "$WT/.launch-state"
grep -v -E '^(BUILT_TREE|BUILD_STATUS|BUILD_ENV|BUILD_CMDS|PATHS_OK|SECRETS_OK|LINT|DB|SHIP_NAME|DB_RESULT|PLANNED)=' "$WT/.launch-state" > "$WT/.launch-tmp" && mv "$WT/.launch-tmp" "$WT/.launch-state"
cfg() { node "$S/cfg.mjs" "$R" "$@"; }
APPDIR="$(cfg appDir "")" || { echo "$APPDIR"; exit 3; }
INSTALL_CFG="$(cfg installCommand "")" || { echo "$INSTALL_CFG"; exit 3; }
BUILD="$(cfg buildCommand "")" || { echo "$BUILD"; exit 3; }
ENVF="$(cfg buildEnvFiles "")" || { echo "$ENVF"; exit 3; }
[ "$(git -C "$WT" rev-parse 'HEAD^{tree}')" = "$TREE" ] || { echo "SETUP: the clean copy doesn't hold the commit prepare.sh recorded"; exit 3; }

nenv=0
if [ -n "$ENVF" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if git -C "$WT" ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
      echo "  note: buildEnvFiles: $f is part of the commit, so the committed version is built (not copied)"; continue
    fi
    if [ ! -f "$R/$f" ]; then echo "  note: buildEnvFiles: $f isn't in your folder, skipped"; continue; fi
    if ! git -C "$R" check-ignore -q -- "$f"; then
      echo "  note: buildEnvFiles: $f isn't ignored by git, so it isn't copied (only ignored files like .env.local are; a"
      echo "        file you simply forgot to commit must be committed)"; continue
    fi
    mkdir -p "$(dirname "$WT/$f")" && cp "$R/$f" "$WT/$f" && nenv=$((nenv + 1))
  done <<<"$ENVF"
  [ $nenv -gt 0 ] && echo "Copied $nenv env file(s) into the clean copy for the build (never pushed)."
fi

D="$WT${APPDIR:+/$APPDIR}"
[ -d "$D" ] || { echo "SETUP: \"appDir\" is \"$APPDIR\", but that folder isn't in this commit"; exit 3; }
cd "$D" || exit 3
if [ -z "$APPDIR" ] && [ -z "$BUILD" ] && [ ! -f package.json ]; then
  nested="$(git -C "$WT" ls-files -- '*/package.json' | grep -v 'node_modules/' | head -3)"
  if [ -n "$nested" ]; then
    echo "APP_IN_SUBFOLDER: there's no package.json at the top of the repo, but there is one in:"; echo "$nested" | sed 's/^/   /'
    echo "Set \"appDir\" (for example \"frontend\") or \"buildCommand\" in .claude/launchcodes.json, then run /launchcodes again."
    exit 3
  fi
fi

if   [ -f pnpm-lock.yaml ]; then PM=pnpm; INSTALL="pnpm install --frozen-lockfile"
elif [ -f yarn.lock ];      then PM=yarn; if [ -f .yarnrc.yml ]; then INSTALL="yarn install --immutable"; else INSTALL="yarn install --frozen-lockfile"; fi
elif [ -f bun.lockb ] || [ -f bun.lock ]; then PM=bun; INSTALL="bun install --frozen-lockfile"
elif [ -f package-lock.json ]; then PM=npm; INSTALL="npm ci --no-audit --no-fund"
elif [ -f package.json ];   then PM=npm; INSTALL="npm install --no-audit --no-fund"
else PM=""; INSTALL=""; fi
[ -n "$INSTALL_CFG" ] && INSTALL="$INSTALL_CFG"
if [ -n "$PM" ] && [ -z "$INSTALL_CFG" ] && ! command -v "$PM" >/dev/null 2>&1; then
  echo "SETUP: this project uses $PM, which isn't installed here (try:  corepack enable )"; exit 3
fi
if [ -z "$BUILD" ] && [ -f package.json ]; then
  has="$(node -e 'try { const p = require(require("path").resolve("package.json")); process.stdout.write(p.scripts && p.scripts.build ? "yes" : "no"); } catch (e) { process.stdout.write("error: " + e.message); }')"
  case "$has" in yes) BUILD="$PM run build" ;; no) ;; *) echo "SETUP: can't read package.json: $has"; exit 3 ;; esac
fi

if [ -n "$INSTALL" ]; then
  echo "Installing: $INSTALL"
  ( eval "$INSTALL" ) > "$WT/.launch-install.log" 2>&1; i=$?
  if [ $i -ne 0 ]; then echo "INSTALL FAILED (exit $i). Last lines:"; tail -25 "$WT/.launch-install.log"; echo "BUILD_FAILED"; exit 1; fi
fi
if [ -n "$BUILD" ]; then
  echo "Building: $BUILD"; t0=$(date +%s)
  ( set -o pipefail; eval "$BUILD" ) > "$WT/.launch-build.log" 2>&1; b=$?; s=$(( $(date +%s) - t0 ))
  if [ $b -ne 0 ]; then
    echo "BUILD FAILED (exit $b, ${s}s). Last lines:"; tail -40 "$WT/.launch-build.log"
    if grep -qiE 'environment variable|supabaseUrl is required|Invalid environment variables|missing (required )?env|is not set in the environment' "$WT/.launch-build.log"; then
      echo "HINT: this build seems to need environment variables. The clean copy has only committed files, so no .env files."
      echo "      If your build reads one (say .env.local), add  \"buildEnvFiles\": [\".env.local\"]  to .claude/launchcodes.json."
      echo "      Careful: the build runs BEFORE your yes. If it migrates, uploads or calls real services with those"
      echo "      settings, that happens before you approve: point them at test values, or take those steps out of the build."
    fi
    echo "BUILD_FAILED"; exit 1
  fi
  STATUS=passed; echo "Build finished in ${s}s."
else
  STATUS=skipped; echo "No build step (no build script and no buildCommand): nothing to compile."
fi
# File names with a content hash (index-DZhMrgGv.js, main.3f2a1b4c.css) let the live check spot this exact build on
# your domain, even when your host hides each deployment's own address behind a login.
: > "$WT/.launch-assets"
if [ "$STATUS" = passed ]; then
  for o in dist build out .next/static; do [ -d "$D/$o" ] && find "$D/$o" -type f \( -name '*.js' -o -name '*.css' \) 2>/dev/null; done \
    | sed 's#.*/##' | grep -E '[-.][A-Za-z0-9_-]{8,}\.(js|css)$' | sort -u | head -200 > "$WT/.launch-assets"
fi
cmds="${INSTALL:-no install}; ${BUILD:-no build}"
{ printf 'BUILT_TREE=%q\n' "$TREE"; printf 'BUILD_STATUS=%q\n' "$STATUS"; printf 'BUILD_ENV=%q\n' "$nenv"; printf 'BUILD_CMDS=%q\n' "$cmds"; } >> "$WT/.launch-state"
if [ "$STATUS" = passed ]; then echo "BUILD_PASSED"; else echo "BUILD_SKIPPED"; fi
echo "NEXT: check"
