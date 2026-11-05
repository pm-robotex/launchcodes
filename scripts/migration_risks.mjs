#!/usr/bin/env node
// migration_risks.mjs < a diff of the release's migration files (git diff -U0)
// Prints the added SQL statements that can break the version that is live while they run, one per line:
//   <file>:<line>  <statement>   <- <why>
// A migration runs before the new code is live (applied by hand before the push, or by the deploy while it builds),
// so for a while the OLD code meets the NEW schema: a dropped or renamed column, a changed type or a new required
// column can break it, and deleted rows don't come back. Comments are skipped, and so is the body of a function
// (it runs when called, not now); a DO block runs now, so it is read.
// Exit: 0 always (it only reports)
import { readFileSync } from 'node:fs';

const RULES = [
  [/\bdrop\s+(table|column|schema|type)\b/i, (m) => `removes a ${m[1].toLowerCase()} the live version may still use`],
  [/\btruncate\b/i, () => 'deletes every row'],
  [/\bdelete\s+from\b/i, () => 'deletes rows'],
  [/\brename\s+(to|column)\b/i, () => 'renames: the live version still uses the old name'],
  [/\balter\s+column\b.*\b(set\s+data\s+)?type\b/i, () => "changes a column's type"],
  [/\bset\s+not\s+null\b/i, () => 'makes a column required: writes from the live version may fail'],
];
const addsRequired = (s) => /\badd\s+column\b/i.test(s) && /\bnot\s+null\b/i.test(s) && !/\bdefault\b/i.test(s);

let file = '', line = 0, body = null;   // body: inside $tag$ ... $tag$ (null outside); body.runs for a DO block
let tail = '';                          // the code just before here, across lines: "DO" may sit on the line above
const out = [];
for (const raw of readFileSync(0, 'utf8').split('\n')) {
  if (raw.startsWith('+++ ')) { file = raw.slice(4).replace(/^b\//, ''); body = null; tail = ''; continue; }
  const h = /^@@ -\d+(?:,\d+)? \+(\d+)/.exec(raw);
  if (h) { line = Number(h[1]); continue; }
  if (!raw.startsWith('+')) continue;
  const text = raw.slice(1).replace(/^\s*--.*$/, '');
  const at = line++;
  // Walk the dollar quotes on this line: the code between them is a function body (skipped) or a DO block (read).
  let check = '', rest = text;
  for (;;) {
    const m = /\$([A-Za-z_][A-Za-z0-9_]*)?\$/.exec(rest);
    if (!m) { if (!body || body.runs) check += rest; if (!body) tail = (tail + ' ' + rest).slice(-40); break; }
    const before = rest.slice(0, m.index);
    if (!body) {
      check += before; tail = (tail + ' ' + before).slice(-40);
      body = { tag: m[0], runs: /\bdo\s*$/i.test(tail.replace(/--[^\n]*$/, '').trimEnd()) };
    } else if (m[0] === body.tag) { if (body.runs) check += before; body = null; tail = ''; }
    else if (body.runs) check += before + m[0];
    rest = rest.slice(m.index + m[0].length);
  }
  const s = check.replace(/--.*$/, '').trim();
  if (!s) continue;
  let why = '';
  for (const [re, say] of RULES) { const m = re.exec(s); if (m) { why = say(m); break; } }
  if (!why && addsRequired(s)) why = 'adds a required column without a default: inserts from the live version fail';
  if (why) out.push(`${file}:${at}  ${s.length > 100 ? s.slice(0, 97) + '...' : s}   <- ${why}`);
}
if (out.length) console.log(out.join('\n'));
