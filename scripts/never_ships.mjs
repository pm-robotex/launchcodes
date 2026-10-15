#!/usr/bin/env node
// never_ships.mjs <repo> <base> <target> [prodBranch]
// Blocks files that must never be pushed: secrets, keys, local tool config, data exports, and a git repository
// committed by accident. It checks EVERY commit in <base>..<target>, not only the end result, because a file
// added in one commit and deleted in the next is still uploaded with the push.
// Your own patterns: "neverShip" in .claude/launchcodes.json. Exceptions: "allowPaths". Both are regular expressions.
// Exit: 0 PATHS_OK | 1 blocked | 2 the check could not run (never read that as a pass)
import { execFileSync } from 'node:child_process';
import { loadConfig, ConfigError, CONFIG_FILE, regexes } from './cfg_lib.mjs';

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const rulesFor = (appDir) => {
  const web = new RegExp(`^(${appDir ? esc(appDir.replace(/[\\/]+$/, '')) + '/' : ''})?(public|static|assets)/`, 'i');
  return [   // [pattern, why, exception]
    [/(^|\/)\.env(\.[^/]*)?$/i, 'environment file (passwords and keys)', /(^|\/)\.env\.(example|sample|template|defaults)$/i],
    [/\.(pem|key|p12|pfx|jks|keystore|p8|ppk)$/i, 'private key or certificate store'],
    [/(^|\/)id_(rsa|ed25519|ecdsa|dsa)$/i, 'SSH private key'],
    [/(^|\/)\.(git-credentials|netrc|pgpass)$/i, 'saved passwords'],
    [/(^|\/)\.dev\.vars$/i, 'local secrets file (Cloudflare)'],
    [/(^|\/)\.claude\/settings\.local\.json$/i, 'your local Claude Code settings'],
    [/(^|\/)supabase\/\.temp\//i, 'Supabase CLI local state'],
    [/(service[-_]?account|credentials|firebase-adminsdk)[^/]*\.json$/i, 'cloud service-account key'],
    [/(^|\/)secrets?\.(json|ya?ml|toml)$/i, 'secrets file'],
    [/\.tfstate(\.backup)?$/i, 'Terraform state (it holds secrets)'],
    [/\.(csv|tsv|xlsx|xlsm|xls|sqlite3?|db|dump|bak|sql\.gz)$/i, 'data export or database file (also blocked in public/, which your host serves to everyone)'],
    [/(^|\/)[^/]*(dump|backup|export)[^/]*\.sql$/i, 'database dump'],
    [/\.(pptx|docx|pdf)$/i, 'document outside public/ (often an internal report)', web],
  ];
};

const [repo, base, target, prod = 'your-production-branch'] = process.argv.slice(2);
try {
  if (!repo || !base || !target) throw new Error('usage: never_ships.mjs <repo> <base> <target> [prodBranch]');
  const cfg = loadConfig(repo);
  const RULES = rulesFor(cfg.appDir || '');
  const extra = regexes(cfg, 'neverShip'), allow = regexes(cfg, 'allowPaths');
  const git = (...a) => execFileSync('git', ['-c', 'core.quotePath=false', '-C', repo, ...a],
    { encoding: 'utf8', maxBuffer: 1 << 30, stdio: ['ignore', 'pipe', 'pipe'] });
  const commits = git('rev-list', '--reverse', `${base}..${target}`).split('\n').filter(Boolean);
  let gitmodules = ''; try { gitmodules = git('show', `${target}:.gitmodules`); } catch { /* no submodules */ }
  const submodules = new Set([...gitmodules.matchAll(/^\s*path\s*=\s*(.+?)\s*$/gm)].map((m) => m[1]));

  const hits = new Map();   // path -> { why, commit }
  for (const c of commits) {
    // -z raw records: ":<old mode> <new mode> <old id> <new id> <status>" NUL "<path>" NUL — safe for any file name
    const parts = git('diff-tree', '-r', '-m', '--root', '--no-commit-id', '--raw', '-z', '--no-renames', '--diff-filter=AM', c).split('\0');
    for (let i = 0; i + 1 < parts.length; i += 2) {
      const meta = parts[i], path = parts[i + 1];
      if (!meta.startsWith(':') || !path || hits.has(path)) continue;
      if (allow.some((r) => r.test(path))) continue;
      if (meta.split(' ')[1] === '160000' && !submodules.has(path)) {
        hits.set(path, { why: 'a folder with its own .git, committed by accident (everyone else gets an empty folder)', c }); continue;
      }
      const rule = RULES.find(([re, , except]) => re.test(path) && !(except && except.test(path)));
      if (rule) { hits.set(path, { why: rule[1], c }); continue; }
      if (extra.some((r) => r.test(path))) hits.set(path, { why: `on your "neverShip" list in ${CONFIG_FILE}`, c });
    }
  }

  if (!hits.size) { console.log(`PATHS_OK — ${commits.length} commit(s) checked`); process.exit(0); }
  console.log('NEVER-SHIPS — these files must not be pushed:');
  for (const [p, h] of hits) console.log(`   ${p}\n      ${h.why}; in commit ${git('log', '-1', '--format=%h "%s"', h.c).trim()}`);
  console.log(`How to fix it, then run /launchcodes again:
 - Deleting the file in a NEW commit still uploads it with the push. Rewrite the commits that aren't live yet:
     git reset --soft origin/${prod}       (keeps every change, staged)
     git rm --cached -- <file>             (keeps the file on your disk)
     add the file to .gitignore, then commit again
 - If it held a password or key that was ever pushed anywhere, treat it as leaked and create a new one.
 - Truly meant to be public? Add its path to "allowPaths" in ${CONFIG_FILE}.`);
  process.exit(1);
} catch (e) {
  if (e instanceof ConfigError) { console.log(`CONFIG_INVALID: ${CONFIG_FILE}: ${e.message}`); process.exit(2); }
  console.log('NEVER-SHIPS CHECK DID NOT RUN: ' + (e.stderr ? String(e.stderr).trim() : e.message));
  process.exit(2);
}
