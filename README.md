# launchcodes

[![selftest](https://github.com/pm-robotex/launchcodes/actions/workflows/selftest.yml/badge.svg)](https://github.com/pm-robotex/launchcodes/actions/workflows/selftest.yml)

**Claude preps the launch. You hold the codes.**

`/launchcodes` is a [Claude Code](https://github.com/anthropics/claude-code) skill that puts your committed work
live, safely. Claude builds the exact commit in a clean copy and runs the checks that catch the classic broken
releases. It gives the release a **launch code** and a plain-language plan, and pushes **only after you say yes**.
Then it waits for your host's production build and, if you tell it your domain, checks that the domain serves it.

Distilled from the release process behind 23+ real production releases of a React + Supabase ERP.

> **v0.1.0, new.** The self-test passes on Windows, macOS and Linux (see the badge), and launchcodes has put real
> releases live on a Vercel site. Other hosts are untested: if you use one, please tell us how it went. Read the
> scripts before you trust them with production: they're short, and each one says what it does at the top.

## A release, start to finish

```
> /launchcodes

  Ship 14Oct-2 · Fix login redirect: ready to put 2 commits live on www.example.com. Nothing has gone live yet.
  - "Fix login redirect loop": signed-out users no longer bounce between /login and /home
  - "Add forgot-password link": a link under the login button
  Checks: build ✓ · secret files ✓ · keys in code ✓ · code check ✓ · database ✓
  When you say yes: Claude Code asks you to approve one command, "Ship 14Oct-2 · PUSH to main (production)".
  That is the launch: choose Yes.

  Ship 14Oct-2 · Fix login redirect: put 2 commits live on www.example.com?
  > Launch 14Oct-2
    Stop, don't launch

  Ship 14Oct-2 · Fix login redirect: Live ✅ www.example.com serves it (17:01 CEST).
```

Every release gets a launch code: the date plus its number that day, like `14Oct-2`. It appears in the plan, the
question, the push prompt and the report, so two releases in one afternoon, or two Claude sessions on one repo,
can't be mixed up.

Try it first with **`/launchcodes dry-run`**: every check and the plan, and nothing is pushed.
`/launchcodes <commit id>` releases that commit (and the ones before it) instead of your latest.

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
  and storage bucket the new code uses, and Claude runs it, or you paste it into the SQL editor.
- **"It returned 200, so it's live."** Single-page apps answer 200 for every address. launchcodes waits for your
  host's production deployment of that exact commit and, if you set your domain, checks what the domain serves:
  its home page must now load a file only this build made (bundlers put a content hash in file names, like
  `index-DZhMrgGv.js`), or match the new deployment's fingerprint. When it can't be sure, it says "Published", with
  the reason, instead of "Live".
- **Someone else pushed in the meantime.** The push refuses, and nothing is overwritten. It never uses `--force`.

## Works with

| | Tested | Should work | Not covered |
|---|---|---|---|
| **Host** | Vercel (a Vite app on its default settings: the live check confirmed "Live") | Any host that deploys when a GitHub branch changes (Netlify, Cloudflare Pages, Render, ...). The live check needs the host to report deployments to GitHub; if it doesn't, launchcodes says so and you look at your host's dashboard. | Hosts you deploy to by hand |
| **App** | JavaScript / TypeScript web apps built with npm | pnpm, yarn and bun; other stacks with `buildCommand` set (the code check is JS-only, and Node is still needed) | |
| **Database** | Supabase (production checked) | Any database: launchcodes never touches it, but only Supabase is checked | |
| **Git** | GitHub | Other git servers: the push works, but the live check needs GitHub | |

## Requirements

- Claude Code (tested with 2.1.296).
- git 2.17+, Node.js 18.18+, and bash. On Windows that's Git Bash, which comes with Git for Windows; Claude Code must
  run the commands through its Bash tool. macOS's built-in bash works.
- A remote called `origin`, and the GitHub CLI `gh`, logged in (`gh auth login`), for the live check.
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

To make sure the push always asks, even if you once chose "don't ask again" or have allowed all Bash commands, add
this `ask` rule to `~/.claude/settings.json` (if the file already exists, add the rule to its `permissions.ask`
list). Only the push uses `--owner-said-yes`, and an ask rule beats an allow rule:

```json
{ "permissions": { "ask": ["Bash(*--owner-said-yes*)"] } }
```

Don't release in a mode that skips permission prompts altogether.

## Configure (optional)

Put a `.claude/launchcodes.json` in your project and commit it (it holds no secrets), so everyone releases with the
same settings. Every key is optional; `examples/launchcodes.json` shows the shape. Its domain and project values are
refused on purpose: put your own, and delete every key you don't need.

| key | default | meaning |
|---|---|---|
| `prodBranch` | origin's default branch | the branch your host deploys to production |
| `domain` | none | your live domain: lets the live check confirm that the domain serves the new build |
| `supabaseProjectRef` | none | your **production** Supabase project, for the database check |
| `appDir` | the repo's top folder | the folder your app lives in, like `"frontend"` |
| `buildCommand`, `installCommand` | from your lockfile (`package-lock.json`, `pnpm-lock.yaml`, ...) and `package.json` | override if needed; they run in the clean copy |
| `buildEnvFiles` | none | files git ignores (like `".env.local"`) to copy from your folder into the clean copy for the build. Never pushed: the push sends the commit, not the folder. Read the warning below first |
| `neverShip` | built-in list | extra paths that must never be pushed |
| `allowPaths` | none | paths to let through anyway |
| `codeCheck` | `true` | `false` switches the JS code check off |
| `lintGlobals` | none | global names your page gets from a `<script>` tag or from your bundler's settings |
| `workDir` | see below | an absolute folder for the clean copies (machine-specific: then don't commit the file) |

`neverShip` and `allowPaths` are regular expressions (search patterns), not `.gitignore` patterns: write
`"\\.sqlite$"`, not `"*.sqlite"` (in JSON, a backslash is written twice). A mistake in this file stops the release
with `CONFIG_INVALID`; it never quietly switches a check off.

**The build runs before you say yes.** Your install and build commands run in step 2, before the plan. With
`buildEnvFiles`, they run with those settings. If they migrate a database, upload files or call real services, that
happens before you approve, even if you then say Stop. Point them at test values, or take those steps out of the
build. launchcodes warns when your build scripts look like they do this. And launch only code you trust: building a
branch runs it.

## What it can't catch

- Keys that don't match one of the known shapes, and anything that was already live before this release.
- TypeScript files (`.ts`, `.tsx`) aren't code-checked; they're covered only if your build runs the TypeScript
  checker (Next.js does; a plain `vite build` doesn't). Runtime and logic bugs aren't caught either: launchcodes is
  not a test suite or CI.
- Differences between the clean copy's build and your host's build settings, such as environment variables. (The
  live check then can't match this build's files on your domain, and says "Published" rather than "Live".)
- Supabase: row-level security policies (the per-row access rules; only table and function permissions are
  checked), table names built at runtime (listed for you to read), schemas other than `public`, and edge functions
  (listed, not checked). Other databases aren't checked at all.
- It never changes your database itself. Your build might (see above), and if your CI or host applies migrations
  when the branch is pushed, the push does.
- It releases one line of commits to one production branch, added on top of what's live. Merges, pull requests and
  multi-branch release flows are out of scope.

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
| `prepare.sh` | checks your tools, works out the commits, warns about uncommitted files and risky build scripts, gives the launch code, makes the clean copy |
| `build.sh` | installs from your lockfile and builds; records the built tree only if both pass |
| `check.sh` | runs `never_ships.mjs`, `secret_scan.mjs`, `scope_lint.mjs` and, for Supabase, `db_refs.mjs` + `refcheck_sql.mjs` |
| `plan.sh` | records the release's name and the exact file list you are approving |
| `push.sh` | pushes only if: the code matches, it's built, checked and planned, the files match your approval, the secret checks still pass, and nobody pushed or rolled back meanwhile |
| `wait_live.sh` | waits for your host's production deployment, then checks your domain serves it: a file only this build made, or the same fingerprint (`etag.sh`) |
| `cleanup.sh` | removes the clean copy |

## Contributing

Reports from macOS and Linux machines are especially welcome: run `tests/selftest.sh` and open an issue with the
output. Found a way around a check? Please report it privately, as [SECURITY.md](SECURITY.md) describes.

## License

MIT. See [LICENSE](LICENSE).
