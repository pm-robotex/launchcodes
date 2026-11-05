#!/usr/bin/env bash
# selftest.sh — runs the launchcodes scripts against throwaway repos, each with a throwaway "origin" (a local bare
# repo). Nothing touches GitHub, your projects or the network: stand-ins play `gh` (GitHub) and `curl` (your site).
# Every clean copy is made inside one temporary folder that is deleted at the end, except one case that checks the
# default place (on Windows the top of the drive), which it removes again.
# Needs bash, git 2.32+, node 18.18+ and npm. With LAUNCHCODES_FULL=1 it also installs ESLint 9 into a test app
# (network) to test the code check end to end.
# Your own git settings (hooks, signing, templates) are ignored for the test repos.
# Prints PASS / FAIL per case; exits 0 only if every case passes.
set -u
S="$(cd "$(dirname "$0")/../scripts" && pwd)"
TMP="$(mktemp -d)" || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/empty-gitconfig"
export GIT_CONFIG_GLOBAL="$TMP/empty-gitconfig"
export GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_0=core.autocrlf GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=commit.gpgsign GIT_CONFIG_VALUE_1=false GIT_CONFIG_KEY_2=init.defaultBranch GIT_CONFIG_VALUE_2=main
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
ROOT="$TMP/with space"; WORK="$ROOT/work"; mkdir -p "$WORK" "$ROOT/bin"
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

pass=0; fail=0
ok()  { echo "PASS  $1"; pass=$((pass + 1)); }
bad() { echo "FAIL  $1"; printf '%s\n' "$2" | sed 's/^/        /'; fail=$((fail + 1)); }
expect() {   # expect <name> <exit code> <text the output must contain> <command...>
  local name="$1" want="$2" grepfor="$3" out rc; shift 3
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" = "$want" ] && grep -q -- "$grepfor" <<<"$out"; then ok "$name"; else bad "$name (exit $rc, wanted $want + '$grepfor')" "$out"; fi
}

# Stand-in for the GitHub CLI. GH_STUB: off (not logged in) | success | failure | inactive | pending | none (nothing
# reported) | multi-ok, multi-fail, multi-building (one commit, two projects: 101 = api, 102 = web) | ctx-pending (the
# deployment is done, but the commit says another project is still building)
cat > "$ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
mode="${GH_STUB:-off}"
if [ "$1" = auth ]; then [ "$mode" = off ] && exit 1; exit 0; fi
[ "$1" = api ] || exit 1
case "$2" in
  */compare/*) echo identical ;;
  *deployments\?sha=*)    # each production deployment of the commit: "<id><TAB><environment>"
    case "$mode" in none) ;; multi-*) printf '101\tProduction – api\n102\tProduction – web\n' ;; *) printf '101\tProduction\n' ;; esac ;;
  *deployments\?per_page=*) [ -n "${STUB_LIVE_SHA:-}" ] && echo "202:$STUB_LIVE_SHA" ;;   # production deployments, newest first
  */deployments/202/statuses*) echo success ;;
  */deployments/102/statuses*) printf '2026-10-14T10:01:00Z\tsuccess\thttps://deploy-2.launchcodes-test.dev\t-\n' ;;
  */deployments/101/statuses*)
    case "$mode" in
      success|multi-ok|ctx-pending) printf '2026-10-14T10:00:00Z\tsuccess\thttps://deploy-1.launchcodes-test.dev\t-\n' ;;
      failure|multi-fail) printf '2026-10-14T10:00:00Z\tfailure\t-\tDeployment was blocked\n' ;;
      inactive) printf '2026-10-14T10:00:00Z\tinactive\t-\t-\n' ;;
      pending|multi-building) printf '2026-10-14T10:00:00Z\tpending\t-\t-\n' ;;
    esac ;;
  */status)     # the commit's combined status: contexts from a host that are still pending
    case "$mode" in pending) echo Vercel ;; ctx-pending) echo "Vercel – api" ;; esac ;;
  */statuses)   # a commit's statuses: counted (length), or read for the reason a deployment failed
    case "$*" in
      *length*) echo 0 ;;
      *'"failure"'*) case "$mode" in failure|multi-fail) printf 'Git author test must have access to the project on Vercel to create deployments.\thttps://vercel.com/test/help\n' ;; esac ;;
    esac ;;
esac
EOF
# Stand-in for curl, as etag.sh calls it: the home page of the domain or of a deployment, with a canned status, ETag
# and page (written to the -o file).
cat > "$ROOT/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=/dev/null; prev=""
for a in "$@"; do [ "$prev" = -o ] && out="$a"; prev="$a"; url="$a"; done
case " $* " in *" --help "*) exit 0 ;; esac
case "$url" in
  */version.txt) st=200; tag=""; body="${STUB_VERSION_BODY:-}" ;;
  */health)   st=200; tag=""; body="${STUB_HEALTH_BODY:-}" ;;
  *deploy-*)  st="${STUB_DEPLOY_STATUS:-200}"; tag="${STUB_DEPLOY_ETAG:-}"; body="" ;;
  */assets/*) st=200; tag=""; body="${STUB_ASSET_BODY:-}" ;;
  *)          st="${STUB_DOMAIN_STATUS:-200}"; tag="${STUB_DOMAIN_ETAG:-}"; body="${STUB_DOMAIN_BODY:-}" ;;
esac
printf '%s' "$body" > "$out"
printf 'HTTP/1.1 %s X\r\n' "$st"; [ -n "$tag" ] && printf 'ETag: "%s"\r\n' "$tag"; printf '\r\n'
EOF
chmod +x "$ROOT/bin/gh" "$ROOT/bin/curl"; export PATH="$ROOT/bin:$PATH"; export GH_STUB=off
# Claude Code settings for the tests, never yours: the ask rule that keeps the push behind a prompt (gate.mjs).
export CLAUDE_CONFIG_DIR="$ROOT/claude-config"; mkdir -p "$CLAUDE_CONFIG_DIR"
printf '{ "permissions": { "ask": ["Bash(*--owner-said-yes*)"] } }\n' > "$CLAUDE_CONFIG_DIR/settings.json"

# Every script parses. (An apostrophe inside ${VAR:+...} once broke a whole script: bash reads it as a quote.)
perr=""
for f in "$S"/*.sh; do e="$(bash -n "$f" 2>&1)" || perr="$perr$(basename "$f"): $e"$'\n'; done
for f in "$S"/*.mjs; do e="$(node --check "$f" 2>&1)" || perr="$perr$(basename "$f"): $e"$'\n'; done
[ -z "$perr" ] && ok "every script parses" || bad "every script parses" "$perr"

new_app() {   # new_app <name>: a bare origin <name>.git and a clone <name> with one commit on main. Prints the clone's path.
  local d="$ROOT/$1"; mkdir -p "$(dirname "$d")"
  git init -q --bare "$d.git"; git -C "$d.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$d.git" "$d" 2>/dev/null; git -C "$d" checkout -q -B main
  printf '{ "name": "t", "version": "1.0.0", "private": true, "scripts": { "build": "node build.js" } }\n' > "$d/package.json"
  cat > "$d/build.js" <<'EOF'
const fs = require('fs');
if (fs.existsSync('BREAK')) { console.error('intentional build error'); process.exit(1); }
if (fs.existsSync('NEEDS_ENV') && !fs.existsSync('.env.local')) { console.error('Error: supabaseUrl is required.'); process.exit(1); }
// Like a bundler: a file named after a hash of what was built, loaded by index.html.
const src = fs.readdirSync('.').filter((f) => !f.startsWith('.launch') && fs.statSync(f).isFile()).sort();
const hash = require('crypto').createHash('sha1').update(src.map((f) => f + fs.readFileSync(f)).join('')).digest('hex').slice(0, 8);
fs.mkdirSync('dist/assets', { recursive: true }); fs.writeFileSync('dist/out.txt', 'built');
fs.writeFileSync(`dist/assets/app-${hash}.js`, 'console.log(1)');
fs.writeFileSync('dist/index.html', `<script type="module" src="/assets/app-${hash}.js"></script>`);
EOF
  printf 'dist/\nnode_modules/\n.env*\n!.env.example\n' > "$d/.gitignore"
  mkdir -p "$d/.claude"; cfgset "$d" ''
  git -C "$d" add -A; git -C "$d" commit -q -m initial; git -C "$d" push -q origin main 2>/dev/null
  git -C "$d" remote set-head origin main >/dev/null 2>&1; git -C "$d" branch -q -u origin/main >/dev/null 2>&1
  printf '%s' "$d"
}
cfgset() { printf '{ "workDir": "%s"%s }\n' "$(winpath "$WORK")" "$2" > "$1/.claude/launchcodes.json"; }
commit() {
  mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add -f -- "$2" && git -C "$1" commit -q -m "$4" || bad "test setup: committing $2" "git add or git commit failed in $1"
}
prep() { OUT="$(bash "$S/prepare.sh" "$@" 2>&1)"; RC=$?; WT="$(sed -n 's/^WT=//p' <<<"$OUT" | head -1)"; CODE="$(sed -n 's/^LAUNCH CODE: //p' <<<"$OUT" | head -1)"; }
full() {      # prepare, build, check, plan. FULL_RC: 0 all passed, else the step that stopped (1-4). CHECK_OUT: check's output.
  CHECK_OUT=""; prep "$@"; [ "$RC" -eq 0 ] || { FULL_RC=1; return; }
  bash "$S/build.sh" "$WT" >/dev/null 2>&1 || { FULL_RC=2; return; }
  CHECK_OUT="$(bash "$S/check.sh" "$WT" 2>&1)" || { FULL_RC=3; return; }
  bash "$S/plan.sh" "$WT" --name 'Test release' >/dev/null 2>&1 || { FULL_RC=4; return; }
  FULL_RC=0
}
done_with() { [ -n "${WT:-}" ] && bash "$S/cleanup.sh" "$WT" >/dev/null 2>&1; git -C "$1" reset -q --hard origin/main; git -C "$1" checkout -q -- .claude/launchcodes.json; }
blocked() {   # blocked <name> <text>: the last full run stopped at the checks and named <text>
  [ "$FULL_RC" = 3 ] && grep -q -- "$2" <<<"$CHECK_OUT" && ok "$1" || bad "$1" "step $FULL_RC: $CHECK_OUT"
}
passes() { [ "$FULL_RC" = 0 ] && ok "$1" || bad "$1" "step $FULL_RC: $OUT $CHECK_OUT"; }

# --- the normal path, and every refusal before the push --------------------------------------------------------
A="$(new_app app)"
expect "nothing to ship when HEAD is already live" 1 NOTHING_TO_SHIP bash "$S/prepare.sh" "$A"
commit "$A" page.txt hello "add a page"; echo notes > "$A/notes.txt"
prep "$A"
[ "$RC" -eq 0 ] && [ -n "$WT" ] && [ -d "$WT" ] && ok "prepare makes a clean copy" || bad "prepare makes a clean copy" "$OUT"
grep -q "NOT part of this release" <<<"$OUT" && ok "prepare warns about uncommitted files" || bad "prepare warns about uncommitted files" "$OUT"
[ ! -e "$WT/notes.txt" ] && ok "the clean copy holds only committed files" || bad "the clean copy holds only committed files" "$(ls -a "$WT")"
[[ "$CODE" =~ ^[0-9]{2}[A-Z][a-z]{2}-1$ ]] && [[ "$WT" =~ -$CODE-[0-9a-f]{4}$ ]] && ok "the release gets a launch code like 14Oct-1, also in its folder name (with 4 random characters)" || bad "the release gets a launch code" "code=$CODE wt=$WT"
WT1="$WT"; CODE1="$CODE"
prep "$A"; [[ "$CODE" == *-2 ]] && ok "a second release the same day gets -2" || bad "a second release the same day gets -2" "$CODE"
grep -q "Not cleaned up yet" <<<"$OUT" && grep -q "$CODE1" <<<"$OUT" && ok "prepare shows a release that is still open" || bad "prepare shows a release that is still open" "$OUT"
bash "$S/cleanup.sh" "$WT" >/dev/null 2>&1; WT="$WT1"; CODE="$CODE1"
expect "plan refuses before a build" 1 "NOT BUILT" bash "$S/plan.sh" "$WT" --name x
expect "push refuses without the owner's yes" 1 "NOT PUSHED" bash "$S/push.sh" "$WT"
expect "build passes" 0 BUILD_PASSED bash "$S/build.sh" "$WT"
expect "plan refuses before the checks" 1 "NOT CHECKED" bash "$S/plan.sh" "$WT" --name x
expect "the checks pass on a clean change" 0 CHECKS_PASSED bash "$S/check.sh" "$WT"
expect "push refuses before a plan" 1 "no plan recorded" bash "$S/push.sh" "$WT" --owner-said-yes="$CODE"
expect "plan refuses a name with a dollar sign" 1 "BAD NAME" bash "$S/plan.sh" "$WT" --name 'costs $5'
expect "plan refuses a name with an apostrophe" 1 "BAD NAME" bash "$S/plan.sh" "$WT" --name "don't panic"
expect "plan works called exactly as SKILL.md writes it" 0 READY_TO_ASK bash -c "bash \"$S/plan.sh\" \"$WT\" --name 'Fix the useAuth loop'"
expect "a name holding a command is refused" 1 "BAD NAME" bash -c "bash \"$S/plan.sh\" \"$WT\" --name 'x \$(touch \"$TMP/pwned\") y'"
[ ! -e "$TMP/pwned" ] && ok "and the command in it never runs" || bad "and the command in it never runs" "$TMP/pwned exists"
expect "plan records the release" 0 READY_TO_ASK bash "$S/plan.sh" "$WT" --name 'Add a page, do not panic'
got="$(bash -c '. "$1/.launch-state"; printf %s "$SHIP_NAME"' _ "$WT")"
[ "$got" = "Add a page, do not panic" ] && ok "the name survives the state file" || bad "the name survives the state file" "$got"
expect "push refuses another release's launch code" 1 "NOT PUSHED" bash "$S/push.sh" "$WT" --owner-said-yes=01Jan-9
cp "$WT/.launch-state" "$TMP/state.good"; cp "$WT/.launch-approved-files" "$TMP/approved.good"
sed 's/^BUILT_TREE=.*/BUILT_TREE=0000000000000000000000000000000000000000/' "$TMP/state.good" > "$WT/.launch-state"
expect "push refuses a commit that wasn't built" 1 NOT_BUILT bash "$S/push.sh" "$WT" --owner-said-yes="$CODE"
grep -v '^SECRETS_OK=' "$TMP/state.good" > "$WT/.launch-state"
expect "push refuses a commit that wasn't checked" 1 NOT_CHECKED bash "$S/push.sh" "$WT" --owner-said-yes="$CODE"
cp "$TMP/state.good" "$WT/.launch-state"; echo extra.txt >> "$WT/.launch-approved-files"
expect "push refuses when the files differ from the approval" 1 FILES_CHANGED bash "$S/push.sh" "$WT" --owner-said-yes="$CODE"
cp "$TMP/approved.good" "$WT/.launch-approved-files"
git clone -q "$A.git" "$ROOT/other" 2>/dev/null; commit "$ROOT/other" theirs.txt theirs "someone else"; git -C "$ROOT/other" push -q origin HEAD:main
expect "push refuses when someone else pushed first" 1 PROD_MOVED bash "$S/push.sh" "$WT" --owner-said-yes="$CODE"
expect "cleanup removes the clean copy" 0 CLEANED bash "$S/cleanup.sh" "$WT"
[ ! -e "$WT" ] && ok "the clean copy is gone" || bad "the clean copy is gone" "$WT still exists"
expect "cleanup refuses a folder that isn't a clean copy" 1 REFUSED bash "$S/cleanup.sh" "$A"
commit "$A" behind.txt behind "work on an old base"
expect "a branch that is behind production is refused" 1 NOT_FAST_FORWARD bash "$S/prepare.sh" "$A"

# --- what goes into a release ------------------------------------------------------------------------------------
M="$(new_app newer)"; commit "$M" one.txt 1 "first change"; first="$(git -C "$M" rev-parse HEAD)"; commit "$M" two.txt 2 "second change"
prep "$M" "$first"
grep -q "NEWER: 1 commit" <<<"$OUT" && [ "$(git -C "$WT" rev-parse HEAD)" = "$first" ] && ok "an older commit can be released, and newer ones are named as left out" || bad "an older commit can be released" "$OUT"
done_with "$M"
commit "$M" wip.txt wip "WIP: try a new login"
prep "$M"; bash "$S/build.sh" "$WT" >/dev/null 2>&1; bash "$S/check.sh" "$WT" >/dev/null 2>&1
expect "the plan flags a work-in-progress commit" 0 SUSPECT bash "$S/plan.sh" "$WT" --name 'Try a new login'
done_with "$M"
mkdir -p "$ROOT/one" "$ROOT/two"; O1="$(new_app one/site)"; O2="$(new_app two/site)"
commit "$O1" a.txt a "a"; commit "$O2" b.txt b "b"
prep "$O1"; W1="$WT"; prep "$O2"; W2="$WT"
[ -n "$W1" ] && [ -n "$W2" ] && [ "$W1" != "$W2" ] && ok "two repos with the same folder name get different clean copies" || bad "two repos with the same folder name get different clean copies" "$W1 / $W2"
bash "$S/cleanup.sh" "$W1" >/dev/null 2>&1; bash "$S/cleanup.sh" "$W2" >/dev/null 2>&1
Z="$(new_app default-place)"; printf '{}\n' > "$Z/.claude/launchcodes.json"; commit "$Z" z.txt z "a change"
prep "$Z"
[ "$RC" -eq 0 ] && [ -d "$WT" ] && ok "with no workDir, the clean copy goes to the default place" || bad "with no workDir, the clean copy goes to the default place" "$OUT"
bash "$S/cleanup.sh" "$WT" >/dev/null 2>&1; [ -n "$WT" ] && [ ! -e "$WT" ] && ok "and cleanup removes it from there" || bad "and cleanup removes it from there" "$WT"

# --- production rolled back while the owner reads the plan ------------------------------------------------------
B="$(new_app rollback)"
commit "$B" x.txt x "x"; git -C "$B" push -q origin main; X="$(git -C "$B" rev-parse HEAD)"
commit "$B" y.txt y "y"; git -C "$B" push -q origin main
commit "$B" z.txt z "z"
full "$B"; [ "$FULL_RC" = 0 ] || bad "rollback setup" "step $FULL_RC: $OUT $CHECK_OUT"
git -C "$B" push -q --force origin "$X:refs/heads/main"
expect "push refuses when production was rolled back meanwhile" 1 PROD_MOVED bash "$S/push.sh" "$WT" --owner-said-yes="$CODE"
bash "$S/cleanup.sh" "$WT" >/dev/null 2>&1

# --- secrets ----------------------------------------------------------------------------------------------------
C="$(new_app secrets)"
commit "$C" .env "SECRET=1" "oops, a secret"; git -C "$C" rm -q --cached .env; git -C "$C" commit -q -m "remove the secret"; rm -f "$C/.env"
full "$C"; blocked "a secret file added and then deleted is still blocked" NEVER-SHIPS
done_with "$C"
b64() { node -e 'process.stdout.write(Buffer.from(process.argv[1]).toString("base64url"))' "$1"; }
hdr="$(b64 '{"alg":"HS256","typ":"JWT"}')"; sig="c2lnbmF0dXJlLWZvci1hLXRlc3Q"
svc="$hdr.$(b64 '{"iss":"supabase","role":"service_role"}').$sig"; anon="$hdr.$(b64 '{"iss":"supabase","role":"anon"}').$sig"
commit "$C" src/db.js "export const key = '$svc';" "connect to the database"
full "$C"; blocked "a service_role key pasted into code is blocked" service_role
! grep -qF "$svc" <<<"$CHECK_OUT" && ok "and the key itself is never printed" || bad "and the key itself is never printed" "$CHECK_OUT"
done_with "$C"
commit "$C" src/db.js "export const key = '$anon';" "connect with the public key"
full "$C"; passes "the public anon key passes"
done_with "$C"
aws="AKIA""ABCDEFGHIJKLMNOP"
commit "$C" src/s3.js "const id = '$aws';" "upload files"
full "$C"; blocked "an AWS key in code is blocked" "AWS access key"
done_with "$C"
commit "$C" src/fixture.js "const id = '$aws'; // launchcodes:allow" "a test fixture"
full "$C"; passes "a line marked launchcodes:allow passes"
done_with "$C"
commit "$C" docs/notes.md "$(printf '%s\n%s' '++ /dev/null' "const key = '$svc';")" "notes with a diff in them"
full "$C"; blocked "a key below text that looks like a diff header is still found" service_role
done_with "$C"
git -C "$C" checkout -q -b side; commit "$C" side.txt side "work on a side branch"; git -C "$C" checkout -q main
commit "$C" mainline.txt mainline "work on main"
git -C "$C" merge -q --no-ff --no-commit side >/dev/null 2>&1; mkdir -p "$C/src"; printf "const k = '%s';\n" "$svc" > "$C/src/merge.js"
git -C "$C" add src/merge.js; git -C "$C" commit -q -m "merge the side branch"
full "$C"; blocked "a key added inside a merge commit is found" service_role
done_with "$C"; git -C "$C" branch -q -D side
tok="sbp""_$(printf 'a1b2c3d4%.0s' 1 2 3 4 5)"
commit "$C" .mcp.json "{ \"env\": { \"SUPABASE_ACCESS_TOKEN\": \"$tok\" } }" "add the MCP config"
full "$C"; blocked "a Supabase access token in .mcp.json is blocked" "Supabase access token"
done_with "$C"
commit "$C" .npmrc "//registry.npmjs.org/:_auth=dXNlcjpwYXNzd29yZA==" "registry login"
full "$C"; blocked "an npm password in .npmrc is blocked" "npm password"
done_with "$C"
commit "$C" src/login.js "let _auth = authenticate(user);" "log in"
full "$C"; passes "ordinary code that mentions _auth passes"
done_with "$C"
commit "$C" .env.example "SUPABASE_URL=" "document the settings"
full "$C"; passes ".env.example is allowed"
done_with "$C"
commit "$C" "data/relatório.csv" "a,b" "add a report"
full "$C"; blocked "a data file with an accented name is blocked" "relatório.csv"
done_with "$C"
commit "$C" public/users.csv "a,b" "share the users"
full "$C"; blocked "a data file in public/ is blocked" "public/users.csv"
[ -n "$WT" ] && bash "$S/cleanup.sh" "$WT" >/dev/null 2>&1
cfgset "$C" ', "allowPaths": ["^public/users\\.csv$"]'
full "$C"; passes "allowPaths lets a chosen file through"
done_with "$C"
X2="$(new_app late-rule)"; commit "$X2" notes/internal.txt x "add notes"
full "$X2"; [ "$FULL_RC" = 0 ] || bad "late-rule setup" "step $FULL_RC: $CHECK_OUT"
cfgset "$X2" ', "neverShip": ["^notes/"]'
expect "push runs the secret-file check again at the last moment" 1 "no longer passes" bash "$S/push.sh" "$WT" --owner-said-yes="$CODE"
done_with "$X2"

# --- configuration mistakes stop the release instead of switching a check off ----------------------------------
D="$(new_app config)"; commit "$D" page.txt x "a change"
printf '{ "workDir": "%s", }\n' "$(winpath "$WORK")" > "$D/.claude/launchcodes.json"
expect "a config file that isn't valid JSON stops the release" 3 CONFIG_INVALID bash "$S/prepare.sh" "$D"
cfgset "$D" ', "neverShip": ["(unclosed"]'
expect "an invalid neverShip pattern stops the release" 3 CONFIG_INVALID bash "$S/prepare.sh" "$D"
cfgset "$D" ', "allowPaths": [""]'
expect "an empty allowPaths entry stops the release" 3 CONFIG_INVALID bash "$S/prepare.sh" "$D"
cfgset "$D" ', "domain": "www.example.com"'
expect "the example domain is refused" 3 "example value" bash "$S/prepare.sh" "$D"
cfgset "$D" ', "prodBranh": "main"'
expect "a misspelt key is refused" 3 "unknown key" bash "$S/prepare.sh" "$D"
cfgset "$D" ', "liveUrl": "/version.txt"'
expect "a liveUrl path without a domain is refused" 3 "is a path" bash "$S/prepare.sh" "$D"
cfgset "$D" ', "liveUrl": "version.txt"'
expect "a liveUrl that is neither an address nor a path is refused" 3 "full address" bash "$S/prepare.sh" "$D"
cfgset "$D" ', "checks": ["npm test", ""]'
expect "an empty check is refused" 3 "is empty" bash "$S/prepare.sh" "$D"
cfgset "$D" ', "deployCommand": "echo a\nrm -rf dist"'
expect "a deployCommand on two lines is refused, so the plan shows all of it" 3 "must be one line" bash "$S/prepare.sh" "$D"
cfgset "$D" ', "domain": "www.launchcodes-test.dev", "liveUrl": ["/version.txt", "health"]'
expect "every page in a liveUrl list is checked" 3 "item 2 must be a full address" bash "$S/prepare.sh" "$D"
cfgset "$D" ', "migrations": "auto"'
expect "migrations takes only the values it knows" 3 "must be one of" bash "$S/prepare.sh" "$D"
printf '\xef\xbb\xbf{ "workDir": "%s" }\n' "$(winpath "$WORK")" > "$D/.claude/launchcodes.json"
prep "$D"; [ "$RC" -eq 0 ] && ok "a config file starting with a byte-order mark is accepted" || bad "a config file starting with a byte-order mark is accepted" "$OUT"
done_with "$D"

# --- builds -----------------------------------------------------------------------------------------------------
E="$(new_app build)"
commit "$E" BREAK "" "break the build"
prep "$E"; expect "a failed build is reported, not hidden" 1 BUILD_FAILED bash "$S/build.sh" "$WT"
grep -q '^BUILT_TREE=' "$WT/.launch-state" && bad "a failed build records no BUILT_TREE" "$(cat "$WT/.launch-state")" || ok "a failed build records no BUILT_TREE"
done_with "$E"
commit "$E" NEEDS_ENV "" "read the settings"
prep "$E"; out="$(bash "$S/build.sh" "$WT" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q HINT <<<"$out" && grep -q "BEFORE your yes" <<<"$out" && ok "a build that needs .env.local fails with a hint and a warning" || bad "a build that needs .env.local fails with a hint" "exit $rc: $out"
bash "$S/cleanup.sh" "$WT" >/dev/null 2>&1
echo "SUPABASE_URL=x" > "$E/.env.local"; cfgset "$E" ', "buildEnvFiles": [".env.local"]'
prep "$E"; expect "buildEnvFiles lets that build pass" 0 BUILD_PASSED bash "$S/build.sh" "$WT"
done_with "$E"; rm -f "$E/.env.local"
commit "$E" src/config.js "committed" "add the config"; echo "local edit" > "$E/src/config.js"
cfgset "$E" ', "buildEnvFiles": ["src/config.js"]'
prep "$E"; out="$(bash "$S/build.sh" "$WT" 2>&1)"
grep -q "part of the commit" <<<"$out" && [ "$(cat "$WT/src/config.js")" = committed ] && ok "buildEnvFiles never overwrites a committed file" || bad "buildEnvFiles never overwrites a committed file" "$out"
done_with "$E"
printf '{ "name": "t", "version": "1.0.0", "private": true, "scripts": { "build": "node build.js", "postbuild": "prisma migrate deploy" } }\n' > "$E/package.json"
git -C "$E" commit -q -am "migrate after the build"
prep "$E"; grep -q "BUILD MAY CHANGE THINGS" <<<"$OUT" && grep -q "prisma migrate deploy" <<<"$OUT" && ok "prepare warns when the build would migrate a database" || bad "prepare warns when the build would migrate a database" "$OUT"
done_with "$E"
F="$(new_app monorepo)"; mkdir -p "$F/frontend"
git -C "$F" mv package.json frontend/package.json; git -C "$F" mv build.js frontend/build.js; git -C "$F" commit -q -m "move the app into frontend/"
prep "$F"; expect "an app in a subfolder asks for appDir" 3 APP_IN_SUBFOLDER bash "$S/build.sh" "$WT"
bash "$S/cleanup.sh" "$WT" >/dev/null 2>&1
cfgset "$F" ', "appDir": "frontend"'
prep "$F"; expect "appDir builds the app in its folder" 0 BUILD_PASSED bash "$S/build.sh" "$WT"
done_with "$F"
G="$(new_app static)"; git -C "$G" rm -q package.json build.js; commit "$G" index.html "<h1>hello</h1>" "a static page"
prep "$G"; expect "a site with nothing to build says BUILD_SKIPPED, not BUILD_PASSED" 0 BUILD_SKIPPED bash "$S/build.sh" "$WT"
done_with "$G"

# --- code check without ESLint, and the database check ----------------------------------------------------------
N="$(new_app nolint)"; commit "$N" src/x.js "export const x = 1;" "a JS change"
full "$N"; [ "$FULL_RC" = 0 ] && grep -q ESLINT_NOT_INSTALLED <<<"$CHECK_OUT" && ok "without ESLint the code check is skipped, and says so" || bad "without ESLint the code check is skipped" "step $FULL_RC: $CHECK_OUT"
done_with "$N"
H="$(new_app supa)"
printf '{ "name": "t", "version": "1.0.0", "private": true, "scripts": { "build": "node build.js" }, "dependencies": { "@supabase/supabase-js": "^2.0.0" } }\n' > "$H/package.json"
git -C "$H" commit -q -am "use supabase"; git -C "$H" push -q origin main; cfgset "$H" ', "installCommand": "true"'
commit "$H" src/orders.js "const { data } = await supabase.from('orders').select('id, total').eq('status', 'open'); const letters = Array.from('abc');" "list the orders"
prep "$H"; bash "$S/build.sh" "$WT" >/dev/null 2>&1; out="$(bash "$S/check.sh" "$WT" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q "BEGIN LAUNCHCODES SQL" <<<"$out" && ok "a Supabase change prints the production query" || bad "a Supabase change prints the production query" "exit $rc: $out"
refs="$(cat "$WT/.launch-refs.json" 2>/dev/null)"
grep -q '"n":"orders"' <<<"$refs" && grep -q '"n":"total"' <<<"$refs" && grep -q '"n":"status"' <<<"$refs" && ok "it finds the table and its columns" || bad "it finds the table and its columns" "$refs"
grep -q '"n":"abc"' <<<"$refs" && bad "Array.from('abc') is not a table" "$refs" || ok "Array.from('abc') is not mistaken for a table"
expect "plan waits for the production query" 1 "DATABASE QUERY NOT RUN" bash "$S/plan.sh" "$WT" --name 'Orders list'
expect "plan accepts --db checked" 0 READY_TO_ASK bash "$S/plan.sh" "$WT" --name 'Orders list' --db checked
done_with "$H"
printf '%s' '{"files":1,"dynamic":[],"refs":[{"k":"table","n":"t","src":"x$j$y$$j$j$z'"'"'); drop table t; --"}]}' > "$TMP/refs.json"
sql="$(node "$S/refcheck_sql.mjs" "$TMP/refs.json")"; lit="$(sed -n "s/.*decode('\([^']*\)', 'hex').*/\1/p" <<<"$sql")"
[ -n "$lit" ] && [[ "$lit" =~ ^[0-9a-f]+$ ]] && ! grep -q 'drop table' <<<"$sql" && ok "a file name can't break out of the production query" || bad "a file name can't break out of the production query" "$sql"

# --- the push, and what follows ---------------------------------------------------------------------------------
P="$(new_app push)"; commit "$P" good.txt good "a good change"
full "$P"; [ "$FULL_RC" = 0 ] || bad "push setup" "step $FULL_RC: $OUT $CHECK_OUT"
expect "a built, checked, planned and approved release is pushed" 0 PUSHED_OK bash "$S/push.sh" "$WT" --owner-said-yes="$CODE"
[ "$(git -C "$P" rev-parse origin/main)" = "$(git -C "$P" rev-parse HEAD)" ] && ok "origin now has exactly that commit" || bad "origin now has exactly that commit" "$(git -C "$P" log --oneline -3 origin/main)"
expect "running the push again does nothing" 0 ALREADY_PUSHED bash "$S/push.sh" "$WT" --owner-said-yes="$CODE"
export GH_STUB=success; expect "with origin off GitHub and no domain set, the live check says so" 3 "NOT GITHUB" bash "$S/wait_live.sh" "$WT" 60
git -C "$P" config remote.origin.url https://github.com/test/launch.git
git -C "$P" config "url.$(winpath "$P.git").insteadOf" https://github.com/test/launch.git
export GH_STUB=off; expect "the live check says so when gh is missing" 6 NO_GH bash "$S/wait_live.sh" "$WT" 60
export GH_STUB=success; expect "with no domain set, the live check reports DEPLOYED" 0 DEPLOYED bash "$S/wait_live.sh" "$WT" 60
export GH_STUB=failure; out="$(bash "$S/wait_live.sh" "$WT" 60 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q BUILD_FAILED <<<"$out" && ok "the live check reports a failed host build" || bad "the live check reports a failed host build" "exit $rc: $out"
grep -q "must have access" <<<"$out" && grep -q "vercel.com/test/help" <<<"$out" && grep -q REFUSING <<<"$out" && ok "and gives the host's own reason, link, and that it's a setting, not the code" || bad "and gives the host's own reason" "$out"
export GH_STUB=none; expect "the live check gives up when no deployment is reported" 4 NO_DEPLOYMENT_REPORTED env POLL=1 GRACE=2 bash "$S/wait_live.sh" "$WT" 60
export GH_STUB=off
PCODE="$CODE"; bash "$S/cleanup.sh" "$WT" >/dev/null 2>&1
commit "$P" more.txt more "one more change"; prep "$P"
grep -q "Last releases" <<<"$OUT" && grep -q "$PCODE" <<<"$OUT" && ok "prepare lists the last releases" || bad "prepare lists the last releases" "$OUT"
bash "$S/cleanup.sh" "$WT" >/dev/null 2>&1
V="$(new_app live)"; cfgset "$V" ', "domain": "www.launchcodes-test.dev"'
git -C "$V" config remote.origin.url https://github.com/test/live.git
git -C "$V" config "url.$(winpath "$V.git").insteadOf" https://github.com/test/live.git
commit "$V" v.txt v "a change to watch go live"
full "$V"; [ "$FULL_RC" = 0 ] || bad "live setup" "step $FULL_RC: $OUT $CHECK_OUT"
expect "the plan lists each commit's files" 0 'v\.txt' bash "$S/plan.sh" "$WT" --name 'Test release'
asset="$(head -1 "$WT/.launch-assets" 2>/dev/null)"
grep -qE '^app-[0-9a-f]{8}\.js$' <<<"$asset" && ok "the build notes the content-hashed files it made" || bad "the build notes the content-hashed files it made" "$(cat "$WT/.launch-assets" 2>&1)"
export STUB_DOMAIN_ETAG=v1 STUB_DOMAIN_BODY='<script type="module" src="/assets/app-0ld0ld00.js"></script>'
expect "with a domain set, the push goes through" 0 PUSHED_OK bash "$S/push.sh" "$WT" --owner-said-yes="$CODE"
grep -q '^ETAG_BEFORE=' "$WT/.launch-state" && grep -q 'app-0ld0ld00' "$WT/.launch-before.html" && ok "and it notes the domain's fingerprint and page before pushing" || bad "and it notes the domain's fingerprint and page before pushing" "$(cat "$WT/.launch-state")"
export GH_STUB=success RETRY_SLEEP=0
export STUB_DOMAIN_ETAG=v2 STUB_DEPLOY_ETAG=v2; expect "LIVE when the domain serves the new deployment" 0 "LIVE:" bash "$S/wait_live.sh" "$WT" 30
export STUB_DOMAIN_ETAG=v1 STUB_DEPLOY_ETAG=v1; expect "an unchanged home page gives DEPLOYED, never LIVE" 0 "same before and after" bash "$S/wait_live.sh" "$WT" 30
export STUB_DOMAIN_ETAG=v1 STUB_DEPLOY_ETAG=v2; expect "a domain serving another build is NOT_CONFIRMED" 5 NOT_CONFIRMED bash "$S/wait_live.sh" "$WT" 30
export STUB_DOMAIN_ETAG=v2 STUB_DEPLOY_ETAG=x STUB_DEPLOY_STATUS=401; expect "a protected deployment address, and the old files still served, give DEPLOYED with the reason" 0 "load a file from this build" bash "$S/wait_live.sh" "$WT" 30
export STUB_DOMAIN_BODY="<script type=\"module\" src=\"/assets/$asset\"></script>"
expect "LIVE when the home page loads a file only this build made, even behind a protected deployment address" 0 "only this build has" bash "$S/wait_live.sh" "$WT" 30
mv "$WT/.launch-before.html" "$WT/.launch-before.bak"
expect "without the page from before the push, that file is not proof" 0 "DEPLOYED" bash "$S/wait_live.sh" "$WT" 30
mv "$WT/.launch-before.bak" "$WT/.launch-before.html"
pushed7="$(git -C "$V" rev-parse --short=7 origin/main)"
export STUB_DOMAIN_BODY='<script type="module" crossorigin src="/assets/main-Zz9.js"></script>' STUB_ASSET_BODY="const BUILD=\"$pushed7\";"
expect "LIVE when the page's main script carries this release's commit id" 0 "carries this release's commit id" bash "$S/wait_live.sh" "$WT" 30
export STUB_ASSET_BODY='const BUILD="0000000";'
expect "another commit id in the script is not proof" 0 "DEPLOYED" bash "$S/wait_live.sh" "$WT" 30
unset STUB_DEPLOY_STATUS STUB_DOMAIN_BODY STUB_ASSET_BODY
export GH_STUB=inactive; expect "a deployment replaced by a newer one is NOT_CONFIRMED" 5 "replaced" bash "$S/wait_live.sh" "$WT" 30
export GH_STUB=pending; expect "a build still running at the time limit says STILL BUILDING, to check again" 2 "STILL BUILDING" env POLL=1 bash "$S/wait_live.sh" "$WT" 2
# Without GitHub's deployment records the live check watches the site itself, for proof only.
export POLL=1 GH_STUB=off STUB_DOMAIN_BODY="<script type=\"module\" src=\"/assets/$asset\"></script>"
out="$(bash "$S/wait_live.sh" "$WT" 30 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q "Watching www.launchcodes-test.dev itself" <<<"$out" && grep -q "only this build has" <<<"$out" \
  && ok "without gh, the live check watches the domain itself" || bad "without gh, the domain is watched" "exit $rc: $out"
export GH_STUB=none; expect "when the host reports nothing to GitHub, the domain itself can show the release" 0 "only this build has" bash "$S/wait_live.sh" "$WT" 30
export STUB_DOMAIN_BODY='<script type="module" src="/assets/app-0ld0ld00.js"></script>'
out="$(env GRACE=1 bash "$S/wait_live.sh" "$WT" 3 2>&1)"; rc=$?
[ "$rc" = 2 ] && grep -q "reports nothing to GitHub" <<<"$out" && grep -q "TIMEOUT.*doesn't show" <<<"$out" \
  && ok "a domain still serving the old version, with nothing reported, is a TIMEOUT, never LIVE" || bad "an unchanged domain is a TIMEOUT" "exit $rc: $out"
export GH_STUB=off STUB_DOMAIN_BODY='<p>a page that changed</p>'
expect "a domain that changed without naming the release is NOT_CONFIRMED" 5 "changed after the push" bash "$S/wait_live.sh" "$WT" 2
export STUB_DOMAIN_STATUS=000 STUB_DOMAIN_BODY=''
expect "a domain that never answers is a TIMEOUT that says so" 2 "didn't answer" bash "$S/wait_live.sh" "$WT" 2
unset STUB_DOMAIN_STATUS
# One commit, two projects (a web app and an API): every production deployment has to succeed.
export STUB_DOMAIN_BODY="<script type=\"module\" src=\"/assets/$asset\"></script>"
export GH_STUB=multi-ok; out="$(bash "$S/wait_live.sh" "$WT" 30 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q "all 2 production deployments built it" <<<"$out" && grep -q "only this build has" <<<"$out" \
  && ok "with two projects, LIVE says both production deployments built it" || bad "two projects, both built" "exit $rc: $out"
export GH_STUB=multi-fail; out="$(bash "$S/wait_live.sh" "$WT" 30 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q BUILD_FAILED <<<"$out" && grep -qF "It failed in: Production – api" <<<"$out" && grep -qF "It built in: Production – web" <<<"$out" \
  && ok "one project's failed build is BUILD_FAILED, even when the other one built later" || bad "one of two projects failed" "exit $rc: $out"
export GH_STUB=multi-building; out="$(env POLL=1 bash "$S/wait_live.sh" "$WT" 2 2>&1)"; rc=$?
[ "$rc" = 2 ] && grep -q "STILL BUILDING" <<<"$out" && grep -qF "Production – api" <<<"$out" && ! grep -q "LIVE:" <<<"$out" \
  && ok "while a second project still builds it is never LIVE, though the domain already serves the new build" || bad "a second project still building" "exit $rc: $out"
export GH_STUB=ctx-pending; out="$(env POLL=1 bash "$S/wait_live.sh" "$WT" 2 2>&1)"; rc=$?
[ "$rc" = 2 ] && grep -qF "STILL BUILDING" <<<"$out" && grep -qF "Vercel – api" <<<"$out" \
  && ok "a project that is building but has no deployment record yet holds the verdict back too" || bad "a pending project without a record" "exit $rc: $out"
export GH_STUB=off
cfgset "$V" ', "domain": "www.launchcodes-test.dev", "liveUrl": "/version.txt"'
export STUB_VERSION_BODY="$pushed7" STUB_DOMAIN_BODY='<script type="module" src="/assets/app-0ld0ld00.js"></script>'
expect "a liveUrl page naming the commit makes it LIVE" 0 "version.txt shows this release's commit id" bash "$S/wait_live.sh" "$WT" 30
export GH_STUB=success; expect "also when the host reports the deployment" 0 "version.txt shows this release's commit id" bash "$S/wait_live.sh" "$WT" 30
export GH_STUB=off STUB_VERSION_BODY="0000000 deployed"
expect "a liveUrl page naming another commit is not proof" 2 TIMEOUT bash "$S/wait_live.sh" "$WT" 2
# Several pages (the web app's version file and an API's health check): each must show the release.
cfgset "$V" ', "domain": "www.launchcodes-test.dev", "liveUrl": ["/version.txt", "https://api.launchcodes-test.dev/health"]'
export STUB_VERSION_BODY="$pushed7" STUB_HEALTH_BODY="{\"commit\":\"$pushed7\"}"
expect "with several liveUrl pages, LIVE needs every one of them" 0 "health shows this release's commit id" bash "$S/wait_live.sh" "$WT" 30
export STUB_HEALTH_BODY='{"commit":"0000000"}'
out="$(bash "$S/wait_live.sh" "$WT" 2 2>&1)"; rc=$?
[ "$rc" = 2 ] && grep -q "api.launchcodes-test.dev/health doesn't show" <<<"$out" && ! grep -q "LIVE:" <<<"$out" \
  && ok "one page still on the old version keeps the release from LIVE" || bad "one of several pages is behind" "exit $rc: $out"
cfgset "$V" ', "domain": "www.launchcodes-test.dev", "liveUrl": "https://api.launchcodes-test.dev/health"'
export STUB_HEALTH_BODY="{\"commit\":\"$pushed7\"}"
out="$(bash "$S/wait_live.sh" "$WT" 2 2>&1)"; rc=$?
[ "$rc" = 2 ] && grep -q "www.launchcodes-test.dev doesn't show" <<<"$out" \
  && ok "a page on another host doesn't vouch for the domain: the domain needs its own proof" || bad "the domain needs its own proof" "exit $rc: $out"
cfgset "$V" ', "domain": "www.launchcodes-test.dev"'
export GH_STUB=off; unset STUB_DOMAIN_ETAG STUB_DEPLOY_ETAG RETRY_SLEEP POLL STUB_DOMAIN_BODY STUB_VERSION_BODY STUB_HEALTH_BODY
bash "$S/cleanup.sh" "$WT" >/dev/null 2>&1

# --- your own checks, and your own deploy command ----------------------------------------------------------------
CK="$(new_app own-checks)"; cfgset "$CK" ', "checks": ["test -f package.json", "test -d dist"]'
commit "$CK" c.txt c "a change with the owner's own checks"
full "$CK"; [ "$FULL_RC" = 0 ] && grep -q "passed: test -d dist" <<<"$CHECK_OUT" && ok "your own checks run in the clean copy, after the build" || bad "your own checks run" "step $FULL_RC: $CHECK_OUT"
expect "the plan counts them" 0 "your own checks ✓ (2)" bash "$S/plan.sh" "$WT" --name 'Test release'
cfgset "$CK" ', "checks": ["test -f package.json", "true"]'
expect "push refuses when your checks changed after they ran" 1 "your own checks changed" bash "$S/push.sh" "$WT" --owner-said-yes="$CODE"
done_with "$CK"
cfgset "$CK" ', "checks": ["echo the tests said no && exit 3"]'; commit "$CK" c2.txt c "a change the owner's tests reject"
full "$CK"; blocked "a failing check of your own blocks the release" "FAILED (exit 3)"
grep -q "the tests said no" <<<"$CHECK_OUT" && ok "and shows what it printed" || bad "a failing check shows its output" "$CHECK_OUT"
done_with "$CK"
DP="$(new_app own-deploy)"; dcmd='echo $LAUNCH_CODE $LAUNCH_COMMIT > deployed.txt && echo uploaded'
cfgset "$DP" ", \"deployCommand\": \"$dcmd\""; commit "$DP" d.txt d "a change for your own server"
full "$DP"; [ "$FULL_RC" = 0 ] || bad "deploy setup" "step $FULL_RC: $OUT $CHECK_OUT"
expect "the plan shows the deployCommand that runs after the push" 0 "AFTER THE PUSH, under the same yes" bash "$S/plan.sh" "$WT" --name 'Test release'
cfgset "$DP" ', "deployCommand": "echo something else"'
expect "push refuses when the deployCommand changed after the plan" 1 "deployCommand changed" bash "$S/push.sh" "$WT" --owner-said-yes="$CODE"
cfgset "$DP" ", \"deployCommand\": \"$dcmd\""
out="$(bash "$S/push.sh" "$WT" --owner-said-yes="$CODE" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q DEPLOYED_BY_COMMAND <<<"$out" && grep -q uploaded <<<"$out" && [ "$(cat "$WT/deployed.txt" 2>/dev/null)" = "$CODE $(git -C "$DP" rev-parse origin/main)" ] \
  && ok "after the push, the deployCommand runs in the clean copy, told the launch code and commit" || bad "the deployCommand runs after the push" "exit $rc: $out / $(cat "$WT/deployed.txt" 2>&1)"
bash "$S/cleanup.sh" "$WT" >/dev/null 2>&1
cfgset "$DP" ', "deployCommand": "echo the server said no && exit 7"'; commit "$DP" e.txt e "a change whose deploy fails"
full "$DP"; out="$(bash "$S/push.sh" "$WT" --owner-said-yes="$CODE" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q PUSHED_OK <<<"$out" && grep -q "DEPLOY_FAILED (exit 7)" <<<"$out" && grep -q "the server said no" <<<"$out" \
  && ok "a failed deployCommand is reported, and the push stands" || bad "a failed deployCommand is reported" "exit $rc: $out"
expect "and the live check reports DEPLOY_FAILED, without waiting" 1 DEPLOY_FAILED bash "$S/wait_live.sh" "$WT" 30
done_with "$DP"
Q="$(new_app refused)"; commit "$Q" q.txt q "a change the server refuses"
printf '#!/bin/sh\necho "refused by a test hook" >&2\nexit 1\n' > "$Q.git/hooks/pre-receive"; chmod +x "$Q.git/hooks/pre-receive"
full "$Q"; expect "a push the server refuses is reported, and nothing changes" 1 "NOT PUSHED" bash "$S/push.sh" "$WT" --owner-said-yes="$CODE"
bash "$S/cleanup.sh" "$WT" >/dev/null 2>&1
full "$Q" --dry-run; expect "a dry run is never pushed" 1 "dry run" bash "$S/push.sh" "$WT" --owner-said-yes="$CODE"
bash "$S/cleanup.sh" "$WT" >/dev/null 2>&1

# --- choosing a release, and what else a release carries -------------------------------------------------------
K="$(new_app choose)"
expect "with nothing ready, the list says so" 1 NOTHING_READY bash "$S/candidates.sh" "$K"
git -C "$K" checkout -q -b feat-a; commit "$K" a.txt a "feature a"
git -C "$K" checkout -q main; git -C "$K" checkout -q -b old-work; commit "$K" c.txt c "older work"; git -C "$K" checkout -q main
git clone -q "$K.git" "$ROOT/choose-other" 2>/dev/null; commit "$ROOT/choose-other" moved.txt m "main moves on"; git -C "$ROOT/choose-other" push -q origin HEAD:main
git -C "$K" fetch -q origin
git -C "$K" checkout -q -b feat-b origin/main; commit "$K" b.txt b "feature b, on the newest main"
git -C "$K" checkout -q -b feat-c origin/main; commit "$K" d.txt d "feature c, on the newest main"; git -C "$K" checkout -q main
out="$(bash "$S/candidates.sh" "$K" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q "RELEASES READY: 2" <<<"$out" && grep -qE "^  [12]  feat-b " <<<"$out" && grep -qE "^  [12]  feat-c " <<<"$out" \
  && grep -qE "^PICK [12] = $(git -C "$K" rev-parse feat-c)$" <<<"$out" && grep -q "NOT LISTED: 2 other" <<<"$out" \
  && ok "a bare /launchcodes lists only the releases that sit on top of what's live, numbered, with their commit ids" || bad "the release list" "exit $rc: $out"
prep "$K" "$(git -C "$K" rev-parse feat-c)"; KW="$WT"; KC="$CODE"
out="$(bash "$S/candidates.sh" "$K" 2>&1)"
grep "feat-c" <<<"$out" | grep -q "ALREADY BEING LAUNCHED as $KC" && ! grep "feat-b" <<<"$out" | grep -q "ALREADY BEING" \
  && ok "a release with an open launchcodes copy is marked in the list" || bad "an in-flight release is marked" "$out"
prep "$K" "$(git -C "$K" rev-parse feat-c)"
grep -q "($KC)   <- THE SAME COMMIT" <<<"$OUT" && ok "and preparing the same commit again warns about the open copy" || bad "the same commit is flagged" "$OUT"
bash "$S/cleanup.sh" "$WT" >/dev/null 2>&1; bash "$S/cleanup.sh" "$KW" >/dev/null 2>&1
git -C "$K" fetch -q origin; git -C "$K" reset -q --hard origin/main

W2="$(new_app carries)"; mkdir -p "$W2/supabase/migrations"
commit "$W2" supabase/migrations/20260101000000_first.sql "create table t (id int);" "a migration"; git -C "$W2" push -q origin main
commit "$W2" supabase/migrations/20260101000000_first.sql "create table t (id int, name text);" "edit the migration"
commit "$W2" supabase/migrations/20260102000000_second.sql "create table u (id int);" "a second migration"
commit "$W2" supabase/functions/hello/index.ts "export default () => new Response('hi');" "an edge function"
prep "$W2"
grep -q "EDGE FUNCTIONS changed" <<<"$OUT" && grep -q "^   hello$" <<<"$OUT" && ok "prepare lists the edge functions a push won't deploy" || bad "prepare lists the edge functions" "$OUT"
grep -q "MIGRATION FILES in this release: 2" <<<"$OUT" && grep -q "20260101000000_first.sql   <- EDITED" <<<"$OUT" && ok "and the migration files, an edited one marked as such" || bad "and the migration files, an edited one marked" "$OUT"
bash "$S/build.sh" "$WT" >/dev/null 2>&1; bash "$S/check.sh" "$WT" >/dev/null 2>&1
expect "the plan repeats the edge functions" 0 "EDGE FUNCTIONS changed, which pushing does NOT deploy: hello" bash "$S/plan.sh" "$WT" --name 'Hello function'
done_with "$W2"

U="$(new_app undeployed)"; live0="$(git -C "$U" rev-parse HEAD)"
git -C "$U" config remote.origin.url https://github.com/test/undeployed.git
git -C "$U" config "url.$(winpath "$U.git").insteadOf" https://github.com/test/undeployed.git
commit "$U" blocked.txt b "the release the host refused"; git -C "$U" push -q origin main
commit "$U" next.txt n "the next release"
export GH_STUB=success STUB_LIVE_SHA="$live0"; prep "$U"; export GH_STUB=off; unset STUB_LIVE_SHA
grep -q "ALSO GOING LIVE: 1 commit" <<<"$OUT" && grep -q "the release the host refused" <<<"$OUT" && ok "commits already on production that the host never put live are named" || bad "commits the host never put live are named" "$OUT"
bash "$S/cleanup.sh" "$WT" >/dev/null 2>&1
git -C "$U" worktree add -q --detach "$WORK/launch-not-ours" HEAD 2>/dev/null
prep "$U"; ! grep -q "launch-not-ours" <<<"$OUT" && ok "another tool's launch-* folder isn't listed as a leftover clean copy" || bad "another tool's launch-* folder isn't listed" "$OUT"
bash "$S/cleanup.sh" "$WT" >/dev/null 2>&1; git -C "$U" worktree remove --force "$WORK/launch-not-ours" 2>/dev/null

Y="$(new_app named)"; cfgset "$Y" ', "releaseCommit": true'; git -C "$Y" add -A; git -C "$Y" commit -q -m "release commits on"; git -C "$Y" push -q origin main
commit "$Y" one.txt 1 "first feature"; T1="$(git -C "$Y" rev-parse HEAD)"; B1="$(git -C "$Y" rev-parse origin/main)"
full "$Y"; [ "$FULL_RC" = 0 ] || bad "release-commit setup" "step $FULL_RC: $OUT $CHECK_OUT"
grep -q "release commit: they land under one merge commit" <<<"$(bash "$S/plan.sh" "$WT" --name 'Test release' 2>&1)" && ok "the plan names the release commit" || bad "the plan names the release commit" "$(bash "$S/plan.sh" "$WT" --name 'Test release' 2>&1)"
expect "with releaseCommit, the release is pushed" 0 "PUSHED_OK  Ship $CODE · Test release" bash "$S/push.sh" "$WT" --owner-said-yes="$CODE"
M1="$(git -C "$Y" rev-parse origin/main)"
[ "$(git -C "$Y" log -1 --format=%s "$M1")" = "Ship $CODE · Test release" ] && [ "$(git -C "$Y" rev-parse "$M1^1")" = "$B1" ] && [ "$(git -C "$Y" rev-parse "$M1^2")" = "$T1" ] && [ "$(git -C "$Y" rev-parse "$M1^{tree}")" = "$(git -C "$Y" rev-parse "$T1^{tree}")" ] \
  && ok "it lands as one merge commit named after the release, holding exactly the built files" || bad "the release commit" "$(git -C "$Y" log -3 --format='%h %p %s' "$M1")"
bash "$S/cleanup.sh" "$WT" >/dev/null 2>&1
commit "$Y" two.txt 2 "second feature, on a branch without the release commit"
prep "$Y"; [ "$RC" = 0 ] && grep -q "== 1 commit(s) would go live" <<<"$OUT" && ok "the next release lines up although the branch lacks the release commit" || bad "the next release lines up" "$OUT"
bash "$S/cleanup.sh" "$WT" >/dev/null 2>&1
git clone -q "$Y.git" "$ROOT/named-other" 2>/dev/null; commit "$ROOT/named-other" theirs.txt t "someone else's real change"; git -C "$ROOT/named-other" push -q origin HEAD:main
expect "a real change on production that the branch lacks still stops it" 1 NOT_FAST_FORWARD bash "$S/prepare.sh" "$Y"
git -C "$Y" reset -q --hard "$T1"
expect "a commit that is already part of production has nothing to ship" 1 NOTHING_TO_SHIP bash "$S/prepare.sh" "$Y"

J="$(new_app supa-rows)"
printf '{ "name": "t", "version": "1.0.0", "private": true, "scripts": { "build": "node build.js" }, "dependencies": { "@supabase/supabase-js": "^2.0.0" } }\n' > "$J/package.json"
git -C "$J" commit -q -am "use supabase"; git -C "$J" push -q origin main; cfgset "$J" ', "installCommand": "true"'
read -r -d '' JSRC <<'JS'
function buildRow(x) {
  const flag = (c) => { return { on: c, rate: 1 }; };
  return { name: x, gift_wrap: flag(true).on };
}
export async function save(supabase, x) { const row = buildRow(x); return supabase.from('orders').insert([row]); }
export async function bulk(supabase, xs) { const rows = xs.map((x) => ({ total: x })); return supabase.from('orders').insert(rows); }
export async function other(supabase, x) { return supabase.from('orders').upsert(makeRows(x)); }
JS
commit "$J" src/save.js "$JSRC" "save orders"
prep "$J"; bash "$S/build.sh" "$WT" >/dev/null 2>&1; out="$(bash "$S/check.sh" "$WT" 2>&1)"; refs="$(cat "$WT/.launch-refs.json" 2>/dev/null)"
grep -q '"n":"gift_wrap"' <<<"$refs" && grep -q '"n":"name"' <<<"$refs" && grep -q '"n":"total"' <<<"$refs" && ok "the database check reads rows built by a helper function or a .map()" || bad "rows built elsewhere are read" "$refs"
! grep -qE '"n":"(on|rate)"' <<<"$refs" && ok "but not what a function inside that helper returns" || bad "an inner function's return is not a row" "$refs"
grep -q "DYNAMIC.*orders.upsert" <<<"$out" && ok "a row it can't trace is listed for a person to read" || bad "an untraceable row is listed" "$out"
done_with "$J"

# --- the approval gate: the push must stop for a prompt in every permission mode --------------------------------
GT="$(new_app gate)"; commit "$GT" g.txt g "a change behind the gate"; NOCFG="$ROOT/no-claude-config"; mkdir -p "$NOCFG"
expect "without an ask rule for the push, prepare refuses" 3 GATE_MISSING env CLAUDE_CONFIG_DIR="$NOCFG" bash "$S/prepare.sh" "$GT"
! git -C "$GT" worktree list | grep -q 'launch-' && ok "and creates nothing" || bad "a refused prepare creates nothing" "$(git -C "$GT" worktree list)"
OUT="$(env CLAUDE_CONFIG_DIR="$NOCFG" bash "$S/prepare.sh" "$GT" --dry-run 2>&1)"; RC=$?; WT="$(sed -n 's/^WT=//p' <<<"$OUT" | head -1)"
[ "$RC" = 0 ] && grep -q "APPROVAL GATE" <<<"$OUT" && ok "a dry run still works without it, and says so" || bad "a dry run without the rule" "$OUT"
bash "$S/cleanup.sh" "$WT" >/dev/null 2>&1
printf '{ "permissions": { "ask": ["Bash(bash:*)"] } }\n' > "$GT/.claude/settings.local.json"
OUT="$(env CLAUDE_CONFIG_DIR="$NOCFG" bash "$S/prepare.sh" "$GT" 2>&1)"; RC=$?; WT="$(sed -n 's/^WT=//p' <<<"$OUT" | head -1)"
[ "$RC" = 0 ] && ok "an ask rule in the project's local settings counts (bash:* covers the push)" || bad "an ask rule in the project's local settings" "$OUT"
bash "$S/cleanup.sh" "$WT" >/dev/null 2>&1
printf '{ "permissions": { "defaultMode": "bypassPermissions" } }\n' > "$GT/.claude/settings.json"
expect "a project that turns permission prompts off is refused, ask rule or not" 3 GATE_OFF bash "$S/prepare.sh" "$GT"
rm -f "$GT/.claude/settings.json" "$GT/.claude/settings.local.json"
full "$GT"; [ "$FULL_RC" = 0 ] || bad "gate setup" "step $FULL_RC: $OUT $CHECK_OUT"
expect "push checks the gate again, and refuses when the rule is gone" 1 "NOT PUSHED: GATE_MISSING" env CLAUDE_CONFIG_DIR="$NOCFG" bash "$S/push.sh" "$WT" --owner-said-yes="$CODE"
done_with "$GT"
SC="$ROOT/setup-claude-config"; mkdir -p "$SC"; printf '{ "model": "x", "permissions": { "allow": ["Bash(ls)"] } }\n' > "$SC/settings.json"
expect "setup.sh --ask-rule adds the rule" 0 GATE_OK env CLAUDE_CONFIG_DIR="$SC" bash "$S/setup.sh" "$GT" --ask-rule
got="$(node -e 'const j = require(process.argv[1]); process.stdout.write([j.model, j.permissions.allow.join(), j.permissions.ask.join()].join("|"))' "$(winpath "$SC/settings.json")")"
[ "$got" = 'x|Bash(ls)|Bash(*--owner-said-yes*)' ] && ok "and keeps everything else in the file" || bad "setup --ask-rule keeps the rest" "$got"
expect "and says so when it is already there" 0 "ALREADY THERE" env CLAUDE_CONFIG_DIR="$SC" bash "$S/setup.sh" "$GT" --ask-rule
printf '{ "model": ' > "$SC/settings.json"
expect "a settings file it can't read is left alone" 1 REFUSED env CLAUDE_CONFIG_DIR="$SC" bash "$S/setup.sh" "$GT" --ask-rule
[ "$(cat "$SC/settings.json")" = '{ "model": ' ] && ok "untouched" || bad "an unreadable settings file stays untouched" "$(cat "$SC/settings.json")"

# --- picking commits from a branch that doesn't sit on top of production -----------------------------------------
PK="$(new_app pick)"; printf '1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n' > "$PK/x.txt"
git -C "$PK" add x.txt; git -C "$PK" commit -q -m "a file with ten lines"; git -C "$PK" push -q origin main
git -C "$PK" checkout -q -b staging
commit "$PK" a.txt a "feature a"; A1="$(git -C "$PK" rev-parse HEAD)"
commit "$PK" b.txt b "feature b"; B1="$(git -C "$PK" rev-parse HEAD)"
commit "$PK" b.txt "b, improved" "improve feature b"; C1="$(git -C "$PK" rev-parse HEAD)"
sed 's/^1$/1 sandbox only/' "$PK/x.txt" > "$PK/x.tmp" && mv "$PK/x.tmp" "$PK/x.txt"; git -C "$PK" commit -q -am "sandbox-only tweak"; S1="$(git -C "$PK" rev-parse HEAD)"
sed 's/^10$/10 for production/' "$PK/x.txt" > "$PK/x.tmp" && mv "$PK/x.tmp" "$PK/x.txt"; git -C "$PK" commit -q -am "a fix production needs"; D1="$(git -C "$PK" rev-parse HEAD)"
git clone -q "$PK.git" "$ROOT/pick-other" 2>/dev/null; commit "$ROOT/pick-other" hotfix.txt h "a hotfix straight on main"; git -C "$ROOT/pick-other" push -q origin HEAD:main
git -C "$PK" fetch -q origin
OUT="$(bash "$S/prepare.sh" "$PK" "$D1" 2>&1)"; RC=$?
[ "$RC" = 1 ] && grep -q NOT_FAST_FORWARD <<<"$OUT" && grep -q "launchcodes pick" <<<"$OUT" && ok "a branch that doesn't sit on top is refused, with the way to pick from it" || bad "not on top: the pick hint" "$OUT"
full "$PK" --pick "$A1"; [ "$FULL_RC" = 0 ] && ok "one commit picked from that branch goes through every step" || bad "a picked commit, every step" "step $FULL_RC: $OUT $CHECK_OUT"
[ "$(git -C "$WT" rev-parse HEAD^)" = "$(git -C "$PK" rev-parse origin/main)" ] && [ "$(git -C "$WT" diff --name-only HEAD^ HEAD)" = a.txt ] \
  && git -C "$WT" log -1 --format=%B | grep -q "(cherry picked from commit $A1)" \
  && ok "the clean copy is what's live plus that one commit, which says where it came from" || bad "the picked clean copy" "$(git -C "$WT" log --format='%h %s' -3)"
expect "the plan names the commit it was picked from" 0 "(picked from ${A1:0:7})" bash "$S/plan.sh" "$WT" --name 'Test release'
expect "a picked release is pushed" 0 PUSHED_OK bash "$S/push.sh" "$WT" --owner-said-yes="$CODE"
git -C "$PK" cat-file -e origin/main:a.txt 2>/dev/null && ! git -C "$PK" cat-file -e origin/main:b.txt 2>/dev/null && [ "$(git -C "$PK" rev-parse staging)" = "$D1" ] \
  && ok "production got that change and nothing else; the branch it came from is untouched" || bad "what the picked push changed" "$(git -C "$PK" log --oneline -3 origin/main)"
bash "$S/cleanup.sh" "$WT" >/dev/null 2>&1
prep "$PK" --pick "$C1"
[ "$RC" = 1 ] && grep -q PICK_CONFLICT <<<"$OUT" && ! git -C "$PK" worktree list | grep -q 'launch-' && ok "a pick that needs a commit left behind stops, and leaves no copy" || bad "a pick that conflicts" "exit $RC: $OUT"
prep "$PK" --pick "$C1" "$B1"
[ "$RC" = 0 ] && [ "$(git -C "$WT" log --format=%s -2 | tr '\n' '|')" = "improve feature b|feature b|" ] && ok "picks named out of order are applied oldest first" || bad "pick order" "exit $RC: $(git -C "$WT" log --format=%s -3 2>&1) $OUT"
bash "$S/cleanup.sh" "$WT" >/dev/null 2>&1
prep "$PK" --pick "$D1"
[ "$RC" = 0 ] && grep -q "EARLIER CHANGES NOT PICKED: 1" <<<"$OUT" && grep -q "sandbox-only tweak" <<<"$OUT" && ok "an earlier commit that changes the same file and isn't live is named" || bad "earlier changes not picked" "exit $RC: $OUT"
bash "$S/cleanup.sh" "$WT" >/dev/null 2>&1
prep "$PK" --pick "$A1"
[ "$RC" = 1 ] && grep -q NOTHING_TO_SHIP <<<"$OUT" && grep -q "the same change is already live" <<<"$OUT" && ok "a commit whose change is already live (picked before) is left out" || bad "an already-live pick" "exit $RC: $OUT"
git -C "$PK" merge -q --no-ff -m "merge production into staging" origin/main >/dev/null 2>&1; M1="$(git -C "$PK" rev-parse HEAD)"
expect "a merge commit can't be picked" 1 PICK_MERGE bash "$S/prepare.sh" "$PK" --pick "$M1"
git -C "$PK" checkout -q main; git -C "$PK" reset -q --hard origin/main

# --- migrations: applied by you before the push, or by your deploy ----------------------------------------------
MG="$(new_app migrations)"; mkdir -p "$MG/prisma/migrations/20260101_drop_age"
commit "$MG" prisma/migrations/20260101_drop_age/migration.sql 'ALTER TABLE "User" DROP COLUMN "age";' "drop the age column"
prep "$MG"
grep -q "must be on production first" <<<"$OUT" && grep -q "RISKY MIGRATION STATEMENTS: 1" <<<"$OUT" && grep -q "removes a column" <<<"$OUT" \
  && ok "a migration that drops a column is flagged as risky" || bad "a risky migration" "$OUT"
bash "$S/cleanup.sh" "$WT" >/dev/null 2>&1
cfgset "$MG" ', "migrations": "deploy"'
full "$MG"
grep -q "Your deploy applies them when the push lands" <<<"$OUT" && ! grep -q "must be on production first" <<<"$OUT" && grep -q "while the previous version is still live" <<<"$OUT" \
  && ok "with \"migrations\": \"deploy\" it doesn't ask for them on production first" || bad "migrations applied by the deploy" "$OUT"
expect "and the plan says the deploy applies them, and that one is risky" 0 "your deploy applies them when the push lands; RISKY: 1" bash "$S/plan.sh" "$WT" --name 'Test release'
done_with "$MG"

# --- first run: the settings file from the owner's answers -----------------------------------------------------
commit "$J" first.txt f "a change in a project without settings"; rm "$J/.claude/launchcodes.json"
prep "$J"; grep -q "== FIRST RUN" <<<"$OUT" && grep -q "PRODUCTION Supabase project" <<<"$OUT" && ok "a first run offers the settings that complete the checks, Supabase included" || bad "a first run offers the settings" "$OUT"
bash "$S/cleanup.sh" "$WT" >/dev/null 2>&1; git -C "$J" checkout -q -- .claude/launchcodes.json
prep "$J"; ! grep -q "FIRST RUN" <<<"$OUT" && ok "and says nothing once the file exists" || bad "no first-run offer once the file exists" "$OUT"
done_with "$J"
SJ="$(new_app setup)"
expect "setup never overwrites an existing settings file" 1 "already exists" bash "$S/setup.sh" "$SJ" --domain www.launchcodes-test.dev
rm "$SJ/.claude/launchcodes.json"
expect "setup refuses something that isn't a domain" 1 REFUSED bash "$S/setup.sh" "$SJ" --domain 'not a domain'
expect "setup refuses a Supabase id of the wrong shape" 1 REFUSED bash "$S/setup.sh" "$SJ" --domain none --supabase abc
expect "setup refuses the README's example domain" 1 "example value" bash "$S/setup.sh" "$SJ" --domain www.example.com
[ ! -e "$SJ/.claude/launchcodes.json" ] && ok "and keeps nothing after a refusal" || bad "nothing kept after a refusal" "$(cat "$SJ/.claude/launchcodes.json")"
expect "setup writes the file from the owner's answers" 0 WROTE bash "$S/setup.sh" "$SJ" --domain https://www.launchcodes-test.dev/ --supabase abcdefghijklmnopqrst
got="$(node "$S/cfg.mjs" "$SJ" domain "")|$(node "$S/cfg.mjs" "$SJ" supabaseProjectRef "")|$(node "$S/cfg.mjs" "$SJ" prodBranch "")"
[ "$got" = "https://www.launchcodes-test.dev|abcdefghijklmnopqrst|main" ] && ok "with the production branch, domain and project it was given" || bad "setup's values" "$got"
git -C "$SJ" checkout -q -- .claude/launchcodes.json

# --- optional: the code check end to end (needs the network to install ESLint) ---------------------------------
if [ "${LAUNCHCODES_FULL:-0}" = 1 ]; then
  L="$(new_app lint)"
  if (cd "$L" && npm install -D eslint@9.17.0 --no-audit --no-fund >/dev/null 2>&1); then
    git -C "$L" add package.json package-lock.json; git -C "$L" commit -q -m "add eslint"; git -C "$L" push -q origin main
    commit "$L" src/App.jsx "export default function App() { return <UserIcon />; }" "show an icon"
    full "$L"; [ "$FULL_RC" = 3 ] && grep -q "NEW" <<<"$CHECK_OUT" && grep -q UserIcon <<<"$CHECK_OUT" && ok "the code check blocks a component used without an import" || bad "the code check blocks a component used without an import" "step $FULL_RC: $CHECK_OUT"
    done_with "$L"
  else bad "npm install eslint@9" "could not install ESLint (network?)"; fi
fi

echo; echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
