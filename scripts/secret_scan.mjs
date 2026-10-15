#!/usr/bin/env node
// secret_scan.mjs <repo> <base> <target> [prodBranch]
// Looks INSIDE the lines added by every commit in <base>..<target> for text that is unmistakably a secret key,
// including the lines a merge commit adds on its own. Public keys are fine by design and never flagged: Supabase
// anon / sb_publishable_ keys, Firebase web keys. A hit names the commit, file and line, never the secret itself.
// A deliberate test value? List the file in "allowPaths", or end that line with the comment launchcodes:allow.
// Exit: 0 SECRETS_OK | 1 secret-looking text | 2 the scan could not run (never read that as a pass)
import { execFileSync } from 'node:child_process';
import { loadConfig, ConfigError, CONFIG_FILE, regexes } from './cfg_lib.mjs';

// [kind, pattern, only in files matching]
const KINDS = [
  ['private key', /-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----/],
  ['Supabase secret key', /\bsb_secret_[A-Za-z0-9_-]{16,}/],
  ['Supabase access token (it controls your whole Supabase account)', /\bsbp_(?:v\d+_)?[A-Za-z0-9]{32,}\b/],
  ['AWS access key', /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/],
  ['GitHub token', /\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,})/],
  ['Stripe live secret key', /\b(?:sk|rk)_live_[A-Za-z0-9]{20,}/],
  ['Slack token', /\bxox[abposr]-[A-Za-z0-9-]{10,}/],
  ['SendGrid key', /\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{30,}/],
  ['Anthropic API key', /\bsk-ant-[A-Za-z0-9_-]{20,}/],
  ['OpenAI API key', /\bsk-(?:proj|svcacct|admin)-[A-Za-z0-9_-]{20,}/],
  ['npm password or token', /(?:^|[\s:])_(?:authToken|auth|password)\s*=\s*(?!\$\{)\S{8,}/, /(^|\/)\.npmrc$/],
];
// Supabase's legacy keys are JWTs. The anon key is public; the service_role key bypasses row-level security.
const JWT = /\beyJ[A-Za-z0-9_-]{6,}\.(eyJ[A-Za-z0-9_-]{6,})\.[A-Za-z0-9_-]{6,}/g;
const jwtRole = (payload) => { try { return JSON.parse(Buffer.from(payload, 'base64url').toString('utf8')).role; } catch { return undefined; } };
const unquote = (p) => (p.startsWith('"') ? p.slice(1, -1).replace(/\\(.)/g, '$1') : p);

const [repo, base, target, prod = 'your-production-branch'] = process.argv.slice(2);
try {
  if (!repo || !base || !target) throw new Error('usage: secret_scan.mjs <repo> <base> <target> [prodBranch]');
  const allow = regexes(loadConfig(repo), 'allowPaths');
  const git = (...a) => execFileSync('git', ['-c', 'core.quotePath=false', '-C', repo, ...a],
    { encoding: 'utf8', maxBuffer: 1 << 30, stdio: ['ignore', 'pipe', 'pipe'] });
  const hits = [];
  const scan = (text, file, at, commit) => {
    if (text.includes('launchcodes:allow')) return;
    for (const [kind, re, only] of KINDS) if ((!only || only.test(file)) && re.test(text)) hits.push({ kind, file, at, commit });
    for (const m of text.matchAll(JWT)) if (jwtRole(m[1]) === 'service_role') hits.push({ kind: 'Supabase service_role key (it bypasses row-level security)', file, at, commit });
  };
  const usable = (f) => f && !allow.some((r) => r.test(f));

  // 1. Every ordinary commit. A line is structure only between "diff --git" and the first "@@" of that file; after
  //    that its first character decides, so an added line that happens to look like a diff header is still scanned.
  const patch = git('log', '-p', '--no-merges', '--no-color', '--no-ext-diff', '--no-textconv', '-U0', '--format=%x01%h "%s"', `${base}..${target}`);
  let commit = '', file = null, line = 0, header = false;
  for (const l of patch.split('\n')) {
    if (l.startsWith('\x01')) { commit = l.slice(1); file = null; header = false; continue; }
    if (l.startsWith('diff --git ')) { header = true; file = null; continue; }
    if (header) {
      if (l.startsWith('+++ ')) { const p = unquote(l.slice(4)); file = p === '/dev/null' ? null : p.replace(/^b\//, ''); if (!usable(file)) file = null; }
      else if (l.startsWith('@@')) { header = false; const m = /\+(\d+)/.exec(l); line = m ? Number(m[1]) : 0; }
      continue;
    }
    if (l.startsWith('@@')) { const m = /\+(\d+)/.exec(l); line = m ? Number(m[1]) : 0; continue; }
    if (!file || !l.startsWith('+')) continue;
    scan(l.slice(1), file, line++, commit);
  }

  // 2. Merge commits: only the lines a merge adds on its own (new against every parent), from the combined diff.
  for (const mc of git('rev-list', '--merges', `${base}..${target}`).split('\n').filter(Boolean)) {
    const label = git('log', '-1', '--format=%h "%s"', mc).trim();
    let mfile = null, n = 2, mline = 0, mheader = false;
    for (const l of git('diff-tree', '--cc', '-p', '--no-color', '--no-ext-diff', '--no-textconv', '-U0', mc).split('\n')) {
      if (/^diff --(cc|combined) /.test(l)) { mheader = true; const p = unquote(l.replace(/^diff --(cc|combined) /, '')); mfile = usable(p) ? p : null; continue; }
      const hm = /^(@{3,}) [^@]*\+(\d+)/.exec(l);
      if (hm) { mheader = false; n = hm[1].length - 1; mline = Number(hm[2]); continue; }
      if (mheader || !mfile) continue;
      const prefix = l.slice(0, n);
      if (prefix.length < n || /[^+ ]/.test(prefix)) continue;   // a '-' column: the line isn't in the merge result
      const at = mline++;
      if (/^\++$/.test(prefix)) scan(l.slice(n), mfile, at, label);
    }
  }

  if (!hits.length) { console.log('SECRETS_OK — no secret-looking text in the added lines'); process.exit(0); }
  console.log('SECRET-LOOKING TEXT — these lines look like real keys (the keys are not shown here):');
  for (const h of hits.slice(0, 30)) console.log(`   ${h.file}:${h.at}  ${h.kind}\n      in commit ${h.commit}`);
  if (hits.length > 30) console.log(`   ... and ${hits.length - 30} more`);
  console.log(`How to fix it, then run /launchcodes again:
 - Move the key out of the code into an environment variable on your host. Front-end variables
   (VITE_..., NEXT_PUBLIC_..., REACT_APP_...) are bundled into public JavaScript: server-only keys never belong there.
 - Deleting the line in a NEW commit still uploads it with the push. Rewrite the commits that aren't live yet:
     git reset --soft origin/${prod}       (keeps every change, staged), remove the key, commit again
 - If the key was ever pushed anywhere, treat it as leaked: create a new one where you got it.
 - A deliberate test value? End the line with the comment launchcodes:allow, or add the file to "allowPaths" in ${CONFIG_FILE}.`);
  process.exit(1);
} catch (e) {
  if (e instanceof ConfigError) { console.log(`CONFIG_INVALID: ${CONFIG_FILE}: ${e.message}`); process.exit(2); }
  console.log('SECRET SCAN DID NOT RUN: ' + (e.stderr ? String(e.stderr).trim() : e.message));
  process.exit(2);
}
