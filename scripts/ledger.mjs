#!/usr/bin/env node
// ledger.mjs <ships.log>
// The launch ledger lives inside your repo's .git folder (never committed, never pushed). One tab-separated line
// per event: <local time> <code> <PREPARED|PLANNED|PUSHED|LIVE|DEPLOYED|FAILED|UNCONFIRMED|CLEANED> <detail>.
// This prints releases that were prepared but never cleaned up (in flight in another chat, or abandoned) and the
// last three releases that were pushed.
import { readFileSync } from 'node:fs';

let lines = [];
try { lines = readFileSync(process.argv[2], 'utf8').split('\n').filter(Boolean).map((l) => l.split('\t')); }
catch { process.exit(0); }
const ships = new Map();
for (const [when, code, ev, detail = ''] of lines) {
  if (!code || !ev) continue;
  if (!ships.has(code)) ships.set(code, []);
  ships.get(code).push({ when, ev, detail });
}
const nameOf = (evs) => (evs.filter((e) => e.ev === 'PLANNED').pop() || {}).detail || '(not named yet)';
const open = [...ships].filter(([, evs]) => !evs.some((e) => e.ev === 'CLEANED'));
if (open.length) {
  console.log('== Not cleaned up yet (another chat may be using it, or it was abandoned):');
  for (const [code, evs] of open) { const last = evs[evs.length - 1]; console.log(`   ${code} · ${nameOf(evs)}: ${last.ev.toLowerCase()} ${last.when}`); }
}
const pushed = [...ships].filter(([, evs]) => evs.some((e) => e.ev === 'PUSHED')).slice(-3).reverse();
if (pushed.length) {
  console.log('== Last releases from this repo on this machine:');
  for (const [code, evs] of pushed) {
    const p = evs.find((e) => e.ev === 'PUSHED');
    const v = evs.filter((e) => ['LIVE', 'DEPLOYED', 'FAILED', 'UNCONFIRMED'].includes(e.ev)).pop();
    console.log(`   ${code} · ${nameOf(evs)}: pushed ${p.when}${v ? `, ${v.ev.toLowerCase()}` : ''}`);
  }
}
