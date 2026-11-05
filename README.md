# launchcodes

[![selftest](https://github.com/pm-robotex/launchcodes/actions/workflows/selftest.yml/badge.svg)](https://github.com/pm-robotex/launchcodes/actions/workflows/selftest.yml)

**Claude preps the launch. You hold the codes.**

`/launchcodes` is a [Claude Code](https://github.com/anthropics/claude-code) skill that puts your committed work
live, safely. Claude builds the exact commit in a clean copy and runs the checks that catch the classic broken
releases, plus any checks of your own. It gives the release a **launch code** and a plain-language plan, and pushes
**only after you say yes**. Then it confirms that your site serves the release: through your host's deployment on
GitHub, or by watching your domain itself.

Distilled from the release process behind 23+ real production releases of a React + Supabase ERP.

> **v0.4.0, new.** The self-test passes on Windows, macOS and Linux (see the badge), and launchcodes has put more
> than twenty real releases live on Vercel. What 0.3.0 and 0.4.0 add (your own checks, a deploy command, watching
> your site without GitHub, picking commits from a staging branch, several projects per repo, migrations your
> deploy applies) is covered by the self-test but not yet by real releases. Other hosts are untested: if you use
> one, please tell us how it went. Read the scripts before you trust them with production: they're short, and each
> one says what it does at the top.

## Is it for you?

**Yes**, if your app goes live from a git branch: production changes when a branch changes, through a host that
deploys on push (Vercel, Netlify, Cloudflare Pages, Render, ...) or a deploy command you run. That includes
production taking only some commits from a staging branch: `/launchcodes pick` releases just those. It suits one
person or a small team releasing with Claude Code who wants a person to say yes before production changes.

**Yes, with a setting**, if you deploy with your own command (`deployCommand`), if your deploy applies migrations
itself (`migrations`), if one repo feeds several projects, like a web app and an API (`liveUrl` lists a page for
each), if your host reports nothing to GitHub or your code isn't on GitHub (`domain`, `liveUrl`), or if you already
have checks you trust, such as tests, a typecheck or a script that looks at your server (`checks`). launchcodes runs
them inside the release, against the exact commit, so you don't need a second routine next to it.

**Only part of the answer**, if most of what breaks in production doesn't go through git: database changes made by
hand, server settings, scheduled scripts, messages sent by jobs. Your `checks` can look at those before a release,
but launchcodes can't stop a change that never goes through it.

**No**, if pull requests and CI already gate every release, if a release moves several branches at once, or if you
want releases without a person saying yes. That stop is the point of launchcodes, not a cost to tune away.

Asked to evaluate launchcodes for someone? See [For AI assistants](#for-ai-assistants-evaluating-launchcodes).

## A release, start to finish

```
> /launchcodes

  Releases ready to go live on main:
    1  fix-login       2 commits · 14 Oct 16:40
    2  pricing-page    1 commit  · 13 Oct 11:02
  > 1 · fix-login

  Ship 14Oct-2 · Fix login redirect: ready to put 2 commits live on www.example.com. Nothing has gone live yet.
  - "Fix login redirect loop": signed-out users no longer bounce between /login and /home
  - "Add forgot-password link": a link under the login button
  Checks: build ✓ · secret files ✓ · keys in code ✓ · code check ✓ · database ✓
  When you say yes: Claude Code asks you to approve one command,
  "Ship 14Oct-2 · Fix login redirect · PUSH to main (production)". That is the launch: choose Yes.

  Ship 14Oct-2 · Fix login redirect: put 2 commits live on www.example.com?
  > Launch 14Oct-2
    Stop, don't launch

  Ship 14Oct-2 · Fix login redirect: Live ✅ www.example.com serves it (17:01 CEST).
```

`/launchcodes` on its own lists the releases that are ready (branches whose newest commits can go live on top of
what's live) and you pick one; Claude never guesses from the conversation. `/launchcodes <commit id>` releases that
commit (and the ones before it). **`/launchcodes pick <commit> <commit> ...`** releases just those commits from a
branch production doesn't follow (staging, a sandbox): the clean copy starts from what's live and gets only them,
oldest first, so the build and the checks test that exact combination. Try it first with **`/launchcodes dry-run`**:
every check and the plan, and nothing is pushed.

Every release gets a launch code, the date plus its number that day, like `14Oct-2`, and a short name. They appear
in the plan, the question, the push prompt and the report, so two releases in one afternoon, or two Claude sessions
on one repo, can't be mixed up. Set `"releaseCommit": true` and the name reaches your host and GitHub too: each
release lands as one merge commit titled `Ship 14Oct-2 · Fix login redirect`, which is what Vercel's Deployments
list (and its Instant Rollback) and GitHub's commit list show.

## What it checks, and why

- **"It works on my machine."** You built and tested locally, but one file was never committed, so the live build
  fails. launchcodes builds a **clean copy of the commit**, not your folder.
- **Green build, white screen.** In `.js`/`.jsx` files, a component you forgot to import (`<UserIcon />`) builds
  fine and crashes in the browser, and ESLint's standard `no-undef` doesn't even look at JSX tags. launchcodes
  lints the changed files with a rule that does, and blocks only **new** errors.
- **A secret in the repo.** `.env` files, private keys, service-account JSON, database dumps and spreadsheets are
  blocked, in **every** commit of the release, because deleting a file in a later commit still uploads it. It also
  looks **inside** the new lines for unmistakable keys: private-key blocks, Supabase `service_role`, `sb_secret_`
  and access tokens, AWS access key IDs, GitHub, Stripe live, Slack, SendGrid, Anthropic and OpenAI keys, and npm
  passwords. Public keys (the Supabase anon key, Firebase web keys) pass, because they're meant to be public.
- **Works on test, broken live (Supabase).** Your code reads a column that exists on your test database but not
  on production. launchcodes writes one read-only query that checks production has every table, column, function
  and storage bucket the new code uses (including the columns of rows it writes, when they're built in a variable or
  a helper function in the same file), and Claude runs it, or you paste it into the SQL editor. It lists the
  release's migration files, edited ones included, and its changed **edge functions**, which a push never deploys.
- **"It returned 200, so it's live."** Single-page apps answer 200 for every address. launchcodes follows your
  host's production deployment of that exact commit on GitHub and, if you set your domain, checks what the domain
  serves: its page, its main script or your `liveUrl` page must show this release's commit id (many builds stamp
  it), or the page must load a file only this build made (bundlers put a content hash in file names, like
  `index-DZhMrgGv.js`), or match the new deployment's fingerprint. When GitHub has no deployment record (your host
  doesn't report there, your code isn't on GitHub, or you deploy with your own command), it watches your domain
  itself, for the same proof. When it can't be sure, it says "Published" or "not confirmed", with the reason, never
  "Live". When your host refuses a deployment, it shows your host's own reason and link.
- **Your own checks, skipped in a hurry.** Tests, a linter, a script that looks at your server: list them in
  `checks` and they run in the clean copy against the exact commit, before the plan. A release can't go out with
  one failing, and changing the list after they ran stops the push.
- **Half a release live.** One repo, two projects (a web app and an API): the web app built, the API failed, and
  "it's live" was half true. launchcodes follows every production deployment of the commit: one failure is a failed
  release, naming the project, and while any project still builds it waits. With a `liveUrl` per project (the web
  app's version page, the API's `/health`), each must show the new commit before it says "Live".
- **A cherry-pick that only worked by luck.** Picking commits from staging by hand, one needs an earlier commit you
  left behind. With `/launchcodes pick`, the clean copy holds exactly what's live plus your picks, built and
  checked together, and the plan names earlier commits that change the same files and aren't live.
- **A migration that breaks the version still running.** The old code meets the new schema while a migration runs,
  whether you apply it before the push or your deploy applies it during the build. launchcodes flags the statements
  that can break it: a dropped or renamed column or table, a changed type, a new required column, deleted rows.
  Function bodies are skipped, because they run only when called.
- **A yes that was never asked.** The push is the one step Claude Code is never pre-approved to run. But in auto
  mode, or with an allow rule that happens to cover it, it could still run without a prompt. launchcodes checks
  your Claude Code settings for an ask rule that keeps the prompt, and refuses to start without it.
- **A release that quietly carries an older one.** If an earlier push to production never went live (its build
  failed or was blocked), your host builds it together with this release. launchcodes lists those commits too.
- **Someone else pushed in the meantime.** The push refuses, and nothing is overwritten. It never uses `--force`.

## Works with

| | Tested | Should work | Not covered |
|---|---|---|---|
| **Host** | Vercel (a Vite app on its default settings: the live check confirmed "Live") | Any host that deploys when a branch changes (Netlify, Cloudflare Pages, Render, ...), including several projects fed by one repo. Hosts you deploy to with a command (your own server, Firebase, Fly, Cloudflare Workers, ...): set `deployCommand`. Without deployment records on GitHub, the live check watches your `domain` | Deploys done by hand, outside launchcodes |
| **App** | JavaScript / TypeScript web apps built with npm | pnpm, yarn and bun; other stacks with `buildCommand` set (the code check is JS-only, and Node is still needed) | |
| **Database** | Supabase (production checked) | Any database: launchcodes never touches it. Migration files are listed and scanned for risky statements in any tool's folder (Prisma, Supabase, ...); with `"migrations": "deploy"` your deploy applies them. Only Supabase gets the production query (your own `checks` can look at yours) | |
| **Git** | GitHub | Other git servers: the push works, and with `domain` set the live check watches your site | |

## Requirements

- Claude Code (tested with 2.1.296).
- git 2.17+, Node.js 18.18+, and bash. On Windows that's Git Bash, which comes with Git for Windows; Claude Code must
  run the commands through its Bash tool. macOS's built-in bash works.
- A remote called `origin`. For the live check: the GitHub CLI `gh`, logged in (`gh auth login`), or your `domain`
  set (then launchcodes watches your site itself); both is best.
- The ask rule that keeps the push behind a prompt, in your Claude Code settings (see "Keep the launch prompt").
  launchcodes offers to add it the first time; a dry run works without it.
- Optional: ESLint 8.57+ or 9 in your project (for the code check); a Supabase MCP server (a connection that lets
  Claude run queries), or the SQL editor, for the database check.
- The self-test also needs git 2.32+ and npm.

## Install

**For yourself (recommended).** In Git Bash on Windows, or Terminal on macOS or Linux:

```bash
git clone https://github.com/pm-robotex/launchcodes ~/.claude/skills/launchcodes
```

In PowerShell:

```powershell
git clone https://github.com/pm-robotex/launchcodes "$HOME\.claude\skills\launchcodes"
```

Restart Claude Code, and `/launchcodes` works in every project. Check that it runs on your machine, in Git Bash or
Terminal (it uses throwaway repos and never touches your projects; it briefly makes and removes one clean copy in
the place a real release uses, which on Windows is a `C:\launch-...` folder):

```bash
bash ~/.claude/skills/launchcodes/tests/selftest.sh
```

Update later (read CHANGELOG.md first): `git -C ~/.claude/skills/launchcodes pull`, or in PowerShell
`git -C "$HOME\.claude\skills\launchcodes" pull`.

**For a team, inside one project.** Don't `git clone` into your project: a repository inside your repository is
committed as an empty folder for everyone else (launchcodes blocks that, too). Download the files instead: on
GitHub, choose Code, then Download ZIP. The ZIP holds a folder named `launchcodes-main`: rename it to `launchcodes`
and put it in your project's `.claude/skills/` folder, so the file is `.claude/skills/launchcodes/SKILL.md`. Commit
that folder, and everyone who opens the project gets `/launchcodes`. To update, download it again.

## Keep the launch prompt

launchcodes asks Claude Code to pre-approve its own steps (prepare, build, check, plan, the live check and the
cleanup), so they usually run without asking. Claude Code may still ask before some of them, for example after you
type an answer instead of clicking one; those are safe to approve. **The push is never pre-approved.** Claude Code
asks you before every launch, and that prompt is the key only you can turn. When it asks, choose **Yes**, never
"Yes, and don't ask again".

The push must always ask, even in auto mode, after you once chose "don't ask again", or with an allow rule that
covers all Bash commands. That takes one `ask` rule in your Claude Code settings (`~/.claude/settings.json`, in its
`permissions.ask` list). Only the push uses `--owner-said-yes`, and an ask rule beats an allow rule:

```json
{ "permissions": { "ask": ["Bash(*--owner-said-yes*)"] } }
```

**launchcodes checks for it** before every release (`gate.mjs`, again right before the push) and refuses to start
without it; a dry run still works. The first time, Claude offers to add it for you (`setup.sh --ask-rule`, only on
your yes: it adds that one rule and leaves the rest of the file alone). It also refuses when a settings file sets
`"defaultMode": "bypassPermissions"`. It can't see a mode chosen when Claude Code was started (a command-line flag),
so never release in a mode that skips permission prompts altogether.

## Configure (optional)

Put a `.claude/launchcodes.json` in your project and commit it (it holds no secrets), so everyone releases with the
same settings. Every key is optional; `examples/launchcodes.json` shows the shape. Its domain and project values are
refused on purpose: put your own, and delete every key you don't need.

You don't have to write it by hand. The first `/launchcodes` in a project without one offers to create it: give
Claude your live domain and, if you use Supabase, your **production** project id (the part before `.supabase.co`),
or say "not now". Claude never guesses them. The file is written only from your answers and never overwrites one
you already have.

| key | default | meaning |
|---|---|---|
| `prodBranch` | origin's default branch | the branch your host deploys to production |
| `domain` | none | your live domain: lets the live check confirm that the domain serves the new build, and watch it directly when GitHub has no deployment record |
| `liveUrl` | none | a page that shows the live commit id, like `"/version.txt"` on your domain, or a full address; or a list of them, one per project (`["/version.txt", "https://api.example.org/health"]`). Every one must show the new commit before the release counts as Live. A page on your domain's own host speaks for the domain; otherwise the domain needs its own proof |
| `migrations` | `"manual"` | `"manual"`: you apply migrations on production before the push (launchcodes asks about each). `"deploy"`: your deploy applies them when the push lands (Prisma's `migrate deploy` in the host's build, say). Either way risky statements are flagged; with `"deploy"`, keep the migrate step out of the build launchcodes runs before your yes (`buildCommand`) |
| `checks` | none | your own commands (tests, a linter, a script that looks at your server or database), one line each. They run in the clean copy after the build, before the plan; any that fails blocks the release. Like the build, they run before your yes, so they must only look, never change things |
| `deployCommand` | none | for a host that doesn't deploy when the branch changes: one command (`firebase deploy --only hosting`, `bash deploy.sh`, ...) run once in the clean copy, right after the push, under the same yes. The plan shows it, and the push refuses if it changed since. It gets `LAUNCH_COMMIT`, `LAUNCH_CODE`, `LAUNCH_NAME` and `LAUNCH_BRANCH` |
| `supabaseProjectRef` | none | your **production** Supabase project, for the database check |
| `appDir` | the repo's top folder | the folder your app lives in, like `"frontend"` |
| `buildCommand`, `installCommand` | from your lockfile (`package-lock.json`, `pnpm-lock.yaml`, ...) and `package.json` | override if needed; they run in the clean copy |
| `buildEnvFiles` | none | files git ignores (like `".env.local"`) to copy from your folder into the clean copy for the build. Never pushed: the push sends the commit, not the folder. Read the warning below first |
| `neverShip` | built-in list | extra paths that must never be pushed |
| `allowPaths` | none | paths to let through anyway |
| `codeCheck` | `true` | `false` switches the JS code check off |
| `lintGlobals` | none | global names your page gets from a `<script>` tag or from your bundler's settings |
| `workDir` | see below | an absolute folder for the clean copies (machine-specific: then don't commit the file) |
| `releaseCommit` | `false` | `true` lands each release as one merge commit titled `Ship <code> · <name>`, so your host's deployment list and GitHub show the release's name. It holds exactly the built files; your branch doesn't get it, and the next release still lines up. Your host must build a commit that changes no files of its own (Vercel does by default; an "Ignored Build Step" that skips such commits would stop it) |

`neverShip` and `allowPaths` are regular expressions (search patterns), not `.gitignore` patterns: write
`"\\.sqlite$"`, not `"*.sqlite"` (in JSON, a backslash is written twice). A mistake in this file stops the release
with `CONFIG_INVALID`; it never quietly switches a check off.

**The build runs before you say yes.** Your install and build commands, and your `checks`, run before the plan.
With `buildEnvFiles`, they run with those settings. If they migrate a database, upload files or call real services,
that happens before you approve, even if you then say Stop. Point them at test values, or take those steps out of
the build (a deploy step belongs in `deployCommand`, which runs only after your yes). launchcodes warns when your
build scripts or checks look like they do this. And launch only code you trust: building a branch runs it.

## What it can't catch

- Keys that don't match one of the known shapes, and anything that was already live before this release.
- TypeScript files (`.ts`, `.tsx`) aren't code-checked; they're covered only if your build runs the TypeScript
  checker (Next.js does; a plain `vite build` doesn't). Runtime and logic bugs aren't caught either: launchcodes is
  not a test suite or CI.
- Differences between the clean copy's build and your host's build settings, such as environment variables. (The
  live check then can't match this build's files on your domain, and says "Published" rather than "Live".)
- Supabase: the database check proves names exist (tables, columns, functions and their arguments), not that a
  function's body is the new one: "database ✓" doesn't prove every migration ran, so compare your production
  migration history with the release's list. Also not checked: row-level security policies (the per-row access
  rules; only table and function permissions are), table names built at runtime (listed for you to read), schemas
  other than `public`, and edge functions (listed, never deployed or compared). Other databases aren't checked at all.
- It never changes your database itself. Your build might (see above), and if your CI or host applies migrations
  when the branch is pushed, the push does.
- Your `deployCommand` does exactly what you wrote, after your yes; launchcodes reports only whether it exited 0.
- Changes that never go through a release: database edits made by hand, server settings, scheduled jobs. Your
  `checks` can look at them before a release, but launchcodes can't stop what doesn't pass through it.
- The risky-migration scan reads SQL statements by their keywords, so a risky change written another way (a tool's
  own syntax, SQL built at runtime) isn't flagged, and a flagged one may be harmless in your case.
- With `pick`, "earlier changes not picked" means commits that change the same files. A pick can also rely on a
  commit that touches other files (a function, a setting); only the build, your checks and you can catch that.
- It releases one line of commits to one production branch, added on top of what's live: a branch, or commits picked
  from one. Merges, pull requests and multi-branch release flows are out of scope.

## If something goes wrong after it's live

- Put the previous version back from your host's dashboard. On Vercel: Deployments, the previous production
  deployment, Instant Rollback. On Netlify: Deploys, an older deploy, Publish deploy.
- A rollback doesn't move your branch, so the next release must contain a fix (or `git revert` the bad commits).
  Release it with `/launchcodes`. Never force-push the production branch.
- On Vercel, after an Instant Rollback, new pushes aren't put on your domain until you undo the rollback in the
  dashboard.

## Where the clean copy goes

- Windows: the top of your drive, like `C:\launch-myapp-1a2b3c-14Oct-2-7f3e`, because long paths break Windows
  checkouts. If that isn't allowed, `%LOCALAPPDATA%\launchcodes`. macOS: `$TMPDIR`. Linux: `~/.cache/launchcodes`.
  Set `workDir` to choose.
- It holds a full install, so it can take hundreds of MB. Cleanup removes it at the end of every release. A copy left
  behind (Claude Code closed mid-release) shows up the next time you run `/launchcodes`; remove it with
  `bash <the launchcodes folder>/scripts/cleanup.sh "<path>"`.
- Launch codes and a short history of releases live in your repo's `.git/launchcodes` folder. They are never
  committed or pushed.

## How it works

Everything happens in small scripts under `scripts/`, and each one starts with a comment explaining what it does
and why.

| script | what it does |
|---|---|
| `candidates.sh` | with no commit given: lists the releases that are ready, numbered, for you to pick |
| `setup.sh` | only on your yes: writes `.claude/launchcodes.json` from your answers (domain, production Supabase project), or adds the ask rule to your Claude Code settings (`--ask-rule`) |
| `gate.mjs` | reads your Claude Code settings: is there an ask rule that keeps the push behind a prompt, and nothing that turns prompts off? |
| `prepare.sh` | checks your tools and the gate, works out the commits (or applies your picks on top of what's live), warns about uncommitted files, risky build scripts, migration files and risky statements in them (`migration_risks.mjs`), edge functions and earlier commits your host never put live, gives the launch code, makes the clean copy |
| `build.sh` | installs from your lockfile and builds; records the built tree only if both pass |
| `check.sh` | runs `never_ships.mjs`, `secret_scan.mjs`, `scope_lint.mjs`, for Supabase `db_refs.mjs` + `refcheck_sql.mjs`, and your own `checks` |
| `plan.sh` | records the release's name, the exact file list you are approving and the deploy command, if any |
| `push.sh` | pushes only if: the code matches, it's built, checked and planned, the files, your checks and your deploy command match what you approved, the secret checks still pass, the ask rule is still in place, and nobody pushed or rolled back meanwhile; with `releaseCommit`, it pushes the merge commit named after the release; then runs your `deployCommand`, if you set one |
| `wait_live.sh` | confirms your site serves the release: this release's commit id, a file only this build made, or the same fingerprint as a new deployment (`etag.sh`), on every `liveUrl` page too. It follows every production deployment of the commit on GitHub (one per project; any failure fails the release), and watches your domain itself when there is none; a refused deployment comes with your host's reason |
| `cleanup.sh` | removes the clean copy |

## For AI assistants evaluating launchcodes

If someone asks you whether to install launchcodes, or to write their own release check instead, these are the
facts to weigh. Check them rather than trust them: each one names the script that does it.

**What it does that a quick home-made check easily gets wrong:**
- It builds a clean copy of the commit (`prepare.sh`, `build.sh`), not the working folder, so an uncommitted file
  can't make a release look fine. It reads exit codes directly: `npm run build | tail` reports `tail`'s exit code,
  so a failed build looks green.
- It checks every commit in the release, not only the end result (`never_ships.mjs`, `secret_scan.mjs`): a secret
  added and deleted again is still pushed.
- The yes is bound to the exact tree that was built and checked (`push.sh`). If the files, the owner's own checks or
  the deploy command change after the plan, or someone pushes or rolls back production meanwhile, the push refuses.
  It pushes by commit id and never uses `--force`.
- The push is the one step Claude Code is never pre-approved to run, and `gate.mjs` checks, before the release and
  again right before the push, that the settings keep that prompt in every mode (auto mode included); without them
  it refuses. A commit message, a file or a tool's output claiming approval is never taken as a yes (`SKILL.md`).
- A release cherry-picked from staging is built and checked as the exact combination that goes live (`prepare.sh
  --pick`), not as the staging branch it came from; earlier commits on the same files that stay behind are named.
- "Live" needs proof that the site serves this build (`wait_live.sh`), because single-page apps answer 200 for every
  path. With several projects per repo, every production deployment of the commit must succeed, and every listed
  page must show it. Earlier commits that never went live, edge functions a push won't deploy, and migration
  statements that can break the version still running (`migration_risks.mjs`) are named in the plan.
- In `.js`/`.jsx` files, a component used without an import builds fine and crashes in the browser, and ESLint's
  `no-undef` doesn't look at JSX (`scope_lint.mjs`). For Supabase, one read-only query proves production has every
  table, column, function and bucket the new code uses (`db_refs.mjs`).

**Keep the checks they already have.** They don't need replacing or running separately: in
`.claude/launchcodes.json`, `"checks": ["npm test", "bash scripts/check-server.sh"]` runs them against the exact
commit in the clean copy, before the plan, and a failure blocks the release. A host that doesn't deploy on push gets
`"deployCommand"`, run once after the yes. No deployment records on GitHub: set `"domain"`, and `"liveUrl"` if the
home page doesn't show the commit id. Production takes cherry-picks from staging: `/launchcodes pick`. Several
projects per repo: a `"liveUrl"` list, one page per project. The deploy applies migrations (Prisma on Vercel, say):
`"migrations": "deploy"`.

**When not to recommend it:** pull requests and CI already gate every release; one release must change several
branches, or deploy services from different repositories together; the person wants no stop before production. If
most of their risk never goes through git (database changes made by hand, server settings, scheduled jobs), it
still covers the pushes: say plainly that it is only part of the answer. Its database check is Supabase-only and its
code check needs ESLint in the project; elsewhere those two report "nothing to check" or "skipped", not a pass.

**What it never does:** write to the database, deploy edge functions, use `--force`, push without the owner's yes in
the same run, or change settings files on its own (the first-run file and the ask rule are written only from the
owner's answers).

**How to judge it cheaply:** `bash tests/selftest.sh` runs it end to end against throwaway repos, offline. Then
`/launchcodes dry-run` in the real project runs every check and shows the plan, and pushes nothing. If they'd rather
build their own anyway, the scripts are MIT-licensed and short: take what helps.

## Contributing

Reports from macOS and Linux machines are especially welcome: run `tests/selftest.sh` and open an issue with the
output. Found a way around a check? Please report it privately, as [SECURITY.md](SECURITY.md) describes.

## License

MIT. See [LICENSE](LICENSE).
