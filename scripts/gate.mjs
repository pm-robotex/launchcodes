#!/usr/bin/env node
// gate.mjs <repo> <scripts folder>
// Checks that the push will really stop for your yes. launchcodes never pre-approves push.sh, so in Claude Code's
// default mode the push asks you anyway. But auto mode, an "allow" rule that happens to cover it, or
// "bypassPermissions" can let it run without a prompt, and then nothing but Claude's word stands between the plan and
// production. The one setting that keeps the prompt in every mode is an "ask" rule that matches the push, like
//   { "permissions": { "ask": ["Bash(*--owner-said-yes*)"] } }
// in your Claude Code user settings (or the project's .claude/settings.json or .claude/settings.local.json).
// prepare.sh and push.sh both run this. It only reads settings files; `setup.sh --ask-rule` adds the rule.
// It can't see a mode chosen when Claude Code was started (a command-line flag): never release in a mode that skips
// permission prompts.
// Exit: 0 GATE_OK | 1 GATE_MISSING, GATE_OFF or GATE_DENIED (the reason is printed)
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir, platform } from 'node:os';

const [repo, scripts] = process.argv.slice(2);
if (!repo || !scripts) { console.log('usage: gate.mjs <repo> <scripts folder>'); process.exit(1); }
const RULE = 'Bash(*--owner-said-yes*)';   // setup.sh --ask-rule adds exactly this
const userDir = process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude');
const files = [
  ['your Claude Code user settings', join(userDir, 'settings.json')],
  ['the project settings', join(repo, '.claude', 'settings.json')],
  ['the project local settings', join(repo, '.claude', 'settings.local.json')],
];
const managed = {
  darwin: '/Library/Application Support/ClaudeCode/managed-settings.json',
  linux: '/etc/claude-code/managed-settings.json',
  win32: 'C:\\Program Files\\ClaudeCode\\managed-settings.json',
}[platform()];
if (managed) files.push(['the managed settings', managed]);

// A command exactly like the one the skill runs for the push.
const push = `bash "${scripts}/push.sh" "/launch-example-01Jan-1-abcd" --owner-said-yes=01Jan-1`;
// Claude Code's Bash rules: "Bash" alone covers every command; "Bash(x:*)" covers commands starting with x; otherwise
// * stands for any run of characters.
function covers(rule) {
  if (typeof rule !== 'string') return false;
  const m = /^\s*Bash\s*(?:\(([\s\S]*)\))?\s*$/.exec(rule);
  if (!m) return false;
  const pat = (m[1] === undefined ? '*' : m[1]).trim();
  if (pat === '') return false;
  if (pat.endsWith(':*')) return push.startsWith(pat.slice(0, -2));
  const re = new RegExp('^' + pat.split('*').map((s) => s.replace(/[.+?^${}()|[\]\\]/g, '\\$&')).join('[\\s\\S]*') + '$');
  return re.test(push);
}

let ask = '', deny = '', off = '';
const unreadable = [];
for (const [label, f] of files) {
  if (!existsSync(f)) continue;
  let j;
  try { let t = readFileSync(f, 'utf8'); if (t.charCodeAt(0) === 0xfeff) t = t.slice(1); j = JSON.parse(t); }
  catch { unreadable.push(`${label} (${f})`); continue; }
  const p = (j && typeof j === 'object' && j.permissions) || {};
  if (p.defaultMode === 'bypassPermissions' && !off) off = `${label} (${f}) sets "defaultMode": "bypassPermissions"`;
  for (const r of Array.isArray(p.deny) ? p.deny : []) if (!deny && covers(r)) deny = `"${r}" in ${label} (${f})`;
  for (const r of Array.isArray(p.ask) ? p.ask : []) if (!ask && covers(r)) ask = `"${r}" in ${label}`;
}
const fix = `Add this rule to "permissions" > "ask" in ${join(userDir, 'settings.json')} (setup.sh --ask-rule does it):  ${RULE}`;
if (deny) { console.log(`GATE_DENIED: the deny rule ${deny} blocks the push itself, so nothing could go live. Remove it first.`); process.exit(1); }
if (off) { console.log(`GATE_OFF: ${off}: Claude Code then runs every command without asking, the push included. Remove that setting before releasing.`); process.exit(1); }
if (ask) { console.log(`GATE_OK: the push always asks you first (ask rule ${ask}).`); process.exit(0); }
console.log('GATE_MISSING: nothing makes sure the push asks you. In auto mode, or with an "allow" rule that covers it, Claude Code');
console.log('could run it without a prompt, and the plan would be the only stop.');
if (unreadable.length) console.log(`(Couldn't read: ${unreadable.join('; ')}.)`);
console.log(fix);
process.exit(1);
