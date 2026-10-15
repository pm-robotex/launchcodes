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

# Stand-in for the GitHub CLI. GH_STUB: off (not logged in) | success | failure | inactive | pending | none (nothing reported)
cat > "$ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
mode="${GH_STUB:-off}"
if [ "$1" = auth ]; then [ "$mode" = off ] && exit 1; exit 0; fi
[ "$1" = api ] || exit 1
case "$2" in
  */compare/*) echo identical ;;
  *deployments\?sha=*) [ "$mode" = none ] || echo 101 ;;
  */deployments/101/statuses*)
    case "$mode" in
      success)  printf '2026-10-14T10:00:00Z\tsuccess\thttps://deploy-1.launchcodes-test.dev\t-\n' ;;
      failure)  printf '2026-10-14T10:00:00Z\tfailure\t-\tbuild error\n' ;;
      inactive) printf '2026-10-14T10:00:00Z\tinactive\t-\t-\n' ;;
      pending)  printf '2026-10-14T10:00:00Z\tpending\t-\t-\n' ;;
    esac ;;
  */statuses) echo 0 ;;
esac
EOF
# Stand-in for curl, as etag.sh calls it: the home page of the domain or of a deployment, with a canned status and ETag.
cat > "$ROOT/bin/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do url="$a"; done
case " $* " in *" --help "*) exit 0 ;; esac
case "$url" in
  *deploy-*) st="${STUB_DEPLOY_STATUS:-200}"; tag="${STUB_DEPLOY_ETAG:-}" ;;
  *)         st="${STUB_DOMAIN_STATUS:-200}"; tag="${STUB_DOMAIN_ETAG:-}" ;;
esac
printf 'HTTP/1.1 %s X\r\n' "$st"; [ -n "$tag" ] && printf 'ETag: "%s"\r\n' "$tag"; printf '\r\n'
EOF
chmod +x "$ROOT/bin/gh" "$ROOT/bin/curl"; export PATH="$ROOT/bin:$PATH"; export GH_STUB=off

new_app() {   # new_app <name>: a bare origin <name>.git and a clone <name> with one commit on main. Prints the clone's path.
  local d="$ROOT/$1"; mkdir -p "$(dirname "$d")"
  git init -q --bare "$d.git"; git -C "$d.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$d.git" "$d" 2>/dev/null; git -C "$d" checkout -q -B main
  printf '{ "name": "t", "version": "1.0.0", "private": true, "scripts": { "build": "node build.js" } }\n' > "$d/package.json"
  cat > "$d/build.js" <<'EOF'
const fs = require('fs');
if (fs.existsSync('BREAK')) { console.error('intentional build error'); process.exit(1); }
if (fs.existsSync('NEEDS_ENV') && !fs.existsSync('.env.local')) { console.error('Error: supabaseUrl is required.'); process.exit(1); }
fs.mkdirSync('dist', { recursive: true }); fs.writeFileSync('dist/out.txt', 'built');
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
[[ "$CODE" =~ ^[0-9]{2}[A-Z][a-z]{2}-1$ ]] && [[ "$WT" == *"-$CODE" ]] && ok "the release gets a launch code like 14Oct-1, also in its folder name" || bad "the release gets a launch code" "code=$CODE wt=$WT"
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
export GH_STUB=off; expect "the live check says so when gh is missing" 6 NO_GH bash "$S/wait_live.sh" "$WT" 60
git -C "$P" config remote.origin.url https://github.com/test/launch.git
git -C "$P" config "url.$(winpath "$P.git").insteadOf" https://github.com/test/launch.git
export GH_STUB=success; expect "with no domain set, the live check reports DEPLOYED" 0 DEPLOYED bash "$S/wait_live.sh" "$WT" 60
export GH_STUB=failure; expect "the live check reports a failed host build" 1 BUILD_FAILED bash "$S/wait_live.sh" "$WT" 60
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
export STUB_DOMAIN_ETAG=v1
expect "with a domain set, the push goes through" 0 PUSHED_OK bash "$S/push.sh" "$WT" --owner-said-yes="$CODE"
grep -q '^ETAG_BEFORE=' "$WT/.launch-state" && ok "and it notes the domain's fingerprint before pushing" || bad "and it notes the domain's fingerprint before pushing" "$(cat "$WT/.launch-state")"
export GH_STUB=success RETRY_SLEEP=0
export STUB_DOMAIN_ETAG=v2 STUB_DEPLOY_ETAG=v2; expect "LIVE when the domain serves the new deployment" 0 "LIVE:" bash "$S/wait_live.sh" "$WT" 30
export STUB_DOMAIN_ETAG=v1 STUB_DEPLOY_ETAG=v1; expect "an unchanged home page gives DEPLOYED, never LIVE" 0 "same before and after" bash "$S/wait_live.sh" "$WT" 30
export STUB_DOMAIN_ETAG=v1 STUB_DEPLOY_ETAG=v2; expect "a domain serving another build is NOT_CONFIRMED" 5 NOT_CONFIRMED bash "$S/wait_live.sh" "$WT" 30
export STUB_DOMAIN_ETAG=v2 STUB_DEPLOY_ETAG=x STUB_DEPLOY_STATUS=401; expect "a protected deployment address gives DEPLOYED, with the reason" 0 "couldn't be compared" bash "$S/wait_live.sh" "$WT" 30
unset STUB_DEPLOY_STATUS
export GH_STUB=inactive; expect "a deployment replaced by a newer one is NOT_CONFIRMED" 5 "replaced" bash "$S/wait_live.sh" "$WT" 30
export GH_STUB=pending; expect "a build that never finishes times out" 2 TIMEOUT env POLL=1 bash "$S/wait_live.sh" "$WT" 2
export GH_STUB=off; unset STUB_DOMAIN_ETAG STUB_DEPLOY_ETAG RETRY_SLEEP
bash "$S/cleanup.sh" "$WT" >/dev/null 2>&1
Q="$(new_app refused)"; commit "$Q" q.txt q "a change the server refuses"
printf '#!/bin/sh\necho "refused by a test hook" >&2\nexit 1\n' > "$Q.git/hooks/pre-receive"; chmod +x "$Q.git/hooks/pre-receive"
full "$Q"; expect "a push the server refuses is reported, and nothing changes" 1 "NOT PUSHED" bash "$S/push.sh" "$WT" --owner-said-yes="$CODE"
bash "$S/cleanup.sh" "$WT" >/dev/null 2>&1
full "$Q" --dry-run; expect "a dry run is never pushed" 1 "dry run" bash "$S/push.sh" "$WT" --owner-said-yes="$CODE"
bash "$S/cleanup.sh" "$WT" >/dev/null 2>&1

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
