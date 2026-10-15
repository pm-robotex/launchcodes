// cfg_lib.mjs — reads and validates <repo>/.claude/launchcodes.json for cfg.mjs and the checks.
// A MISSING file is fine: every key has a default. A file that exists but can't be used throws ConfigError —
// a typo must never quietly switch a safety check off.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

export const CONFIG_FILE = '.claude/launchcodes.json';
export class ConfigError extends Error {}

const KEYS = {
  prodBranch: 'string', domain: 'string', supabaseProjectRef: 'string', appDir: 'dir',
  buildCommand: 'string', installCommand: 'string', workDir: 'abs',
  buildEnvFiles: 'paths', neverShip: 'regexes', allowPaths: 'regexes', lintGlobals: 'names', codeCheck: 'boolean',
};
const EXAMPLE = { domain: /^(https?:\/\/)?(www\.)?example\.(com|org)\/?$/i, supabaseProjectRef: /^your-/i };
const inside = (p) => !(p.startsWith('/') || p.startsWith('\\') || /^[A-Za-z]:/.test(p) || p.split(/[\\/]/).includes('..'));

export function loadConfig(repo) {
  let text;
  try { text = readFileSync(join(repo, CONFIG_FILE), 'utf8'); }
  catch (e) { if (e.code === 'ENOENT') return {}; throw new ConfigError(`can't read it (${e.code || e.message})`); }
  if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);   // a byte-order mark (Windows PowerShell 5.1 writes one)
  let cfg;
  try { cfg = JSON.parse(text); }
  catch (e) { throw new ConfigError(`not valid JSON (${e.message}). Inside JSON text a backslash is written twice, like "\\\\.sqlite$".`); }
  if (!cfg || typeof cfg !== 'object' || Array.isArray(cfg)) throw new ConfigError('must be a JSON object: { "key": value, ... }');
  for (const [k, v] of Object.entries(cfg)) {
    const type = KEYS[k];
    if (!type) throw new ConfigError(`unknown key "${k}" — the keys are: ${Object.keys(KEYS).join(', ')}`);
    if (v === null) continue;
    const fail = (why) => { throw new ConfigError(`"${k}" ${why}`); };
    if (type === 'boolean') { if (typeof v !== 'boolean') fail('must be true or false'); continue; }
    if (type === 'string' || type === 'dir' || type === 'abs') {
      if (typeof v !== 'string' || !v.trim()) fail('must be a non-empty text value');
      if (type === 'dir' && !inside(v)) fail('must be a folder inside your repo, like "frontend"');
      if (type === 'abs' && !(v.startsWith('/') || /^[A-Za-z]:[\\/]/.test(v))) fail('must be an absolute folder path');
      if (EXAMPLE[k] && EXAMPLE[k].test(v)) fail(`still has the example value "${v}" — put your own, or delete the key`);
      continue;
    }
    if (!Array.isArray(v)) fail('must be a list, like ["...", "..."]');
    v.forEach((x, i) => {
      const item = `item ${i + 1}`;
      if (typeof x !== 'string' || !x.trim()) fail(`${item} is empty or not text`);
      if (type === 'regexes') {
        try { new RegExp(x, 'i'); }
        catch (e) { fail(`${item} is not a valid regular expression (${e.message}). These are regular expressions, not .gitignore patterns: write "\\\\.sqlite$", not "*.sqlite".`); }
      }
      if (type === 'paths' && !inside(x)) fail(`${item} must be a path inside your repo, like ".env.local"`);
      if (type === 'names' && !/^[A-Za-z_$][\w$]*$/.test(x)) fail(`${item} is not a JavaScript name`);
    });
  }
  return cfg;
}

export const regexes = (cfg, key) => (cfg[key] || []).map((p) => new RegExp(p, 'i'));
