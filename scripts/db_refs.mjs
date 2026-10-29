#!/usr/bin/env node
// db_refs.mjs <repo> <base> <target> --out <refs.json>
// Lists the Supabase objects (tables, columns, RPC functions and their argument names, storage buckets, edge
// functions) that NEW lines of supabase-js code use between <base> and <target>. Reads files from git at
// <target>, never your working folder. Writes JSON for refcheck_sql.mjs and prints a summary.
// Why: a column that exists only on your test database, used in one .select(), makes that whole query fail for
// every user once the code is live, while it worked perfectly when you tested it.
// Limits: names built at runtime (`.from(tableName)`) can't be checked; they are listed as DYNAMIC for a person
// to read. Only the `public` schema is checked. Row-level security policies are not checked.
// Exit: 0 references found (JSON written) | 3 nothing to check (not a Supabase project, or no references on
//       new lines) | 2 the check could not run
import { execFileSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';

try {
  const [repo, base, target, ...flags] = process.argv.slice(2);
  if (!repo || !base || !target) throw new Error('usage: db_refs.mjs <repo> <base> <target> --out <refs.json>');
  const OUT = flags.includes('--out') ? flags[flags.indexOf('--out') + 1] : null;
  const git = (...a) => execFileSync('git', ['-c', 'core.quotePath=false', '-C', repo, ...a],
    { encoding: 'utf8', maxBuffer: 1 << 28, stdio: ['ignore', 'pipe', 'pipe'] });

  const pkgs = git('ls-tree', '-r', '--name-only', '-z', target).split('\0')
    .filter((f) => /(^|\/)package\.json$/.test(f) && !/(^|\/)node_modules\//.test(f));
  const usesSupabase = pkgs.some((p) => { try { return /"@supabase\/supabase-js"/.test(git('show', `${target}:${p}`)); } catch { return false; } });
  if (!usesSupabase) { console.log('not a Supabase project (no @supabase/supabase-js in package.json): database check not applicable'); process.exit(3); }

  const skip = /(^|\/)(node_modules|dist|build|out|\.next|coverage|vendor)\/|\.min\.js$/;
  const files = git('diff', '--name-only', '-z', '--no-renames', '--diff-filter=AM', base, target)
    .split('\0').filter((f) => /\.(jsx?|tsx?|mjs)$/.test(f) && !skip.test(f));

  const out = new Map(); const dynamic = [];
  const add = (r, where) => {
    const key = [r.k, r.t || '', r.n, (r.args || []).join(',')].join('|');
    if (!out.has(key)) out.set(key, { ...r, src: [] });
    const e = out.get(key); if (e.src.length < 3) e.src.push(where);
  };
  const addedLines = (file) => {
    const set = new Set();
    for (const m of git('diff', '--no-color', '--no-ext-diff', '-U0', '--no-renames', base, target, '--', file)
      .matchAll(/^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/gm)) {
      const start = Number(m[1]), n = m[2] === undefined ? 1 : Number(m[2]);
      for (let i = 0; i < n; i++) set.add(start + i);
    }
    return set;
  };
  const lineIndex = (src) => {
    const starts = [0]; for (let i = 0; i < src.length; i++) if (src[i] === '\n') starts.push(i + 1);
    return (off) => { let lo = 0, hi = starts.length - 1;
      while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (starts[mid] <= off) lo = mid; else hi = mid - 1; } return lo + 1; };
  };
  const skipString = (s, i) => { const q = s[i]; i++; while (i < s.length && s[i] !== q) { if (s[i] === '\\') i++; i++; } return i; };
  const chainEnd = (src, i) => {      // end of a call chain: ';' or ',' at depth 0, or the enclosing ')'
    let depth = 0;
    for (; i < src.length; i++) {
      const c = src[i];
      if (c === "'" || c === '"' || c === '`') { i = skipString(src, i); continue; }
      if ('([{'.includes(c)) depth++; else if (')]}'.includes(c)) { if (--depth < 0) return i; }
      else if ((c === ';' || c === ',') && depth === 0) return i;
    }
    return src.length;
  };
  const balanced = (src, i) => {      // src[i] === '{' -> index of the matching '}'
    let depth = 0;
    for (; i < src.length; i++) {
      const c = src[i];
      if (c === "'" || c === '"' || c === '`') { i = skipString(src, i); continue; }
      if ('([{'.includes(c)) depth++; else if (')]}'.includes(c) && --depth === 0) return i;
    }
    return src.length;
  };
  const topKeys = (obj) => {          // top-level keys of an object literal, each with its offset inside obj
    const keys = [], offs = []; let depth = 0, tok = '', start = -1, spread = false;
    const flush = () => { const t = tok.trim(), at0 = start; tok = ''; start = -1; if (!t) return; if (t.startsWith('...')) { spread = true; return; }
      const m = t.match(/^\[?['"]?([A-Za-z_]\w*)['"]?\]?\s*(:|$)/); if (m) { keys.push(m[1]); offs.push(at0); } };
    for (let i = 1; i < obj.length - 1; i++) {
      const c = obj[i];
      if (c === "'" || c === '"' || c === '`') { const j = skipString(obj, i); if (depth === 0) { if (start < 0) start = i; tok += obj.slice(i, j + 1); } i = j; continue; }
      if ('([{'.includes(c)) depth++; else if (')]}'.includes(c)) depth--;
      if (depth === 0 && c === ',') flush(); else if (depth === 0) { if (start < 0 && !/\s/.test(c)) start = i; tok += c; }
    }
    flush(); return { keys, offs, spread };
  };
  const selectCols = (s) => {         // PostgREST select string -> columns + embedded relations
    const cols = [], embeds = []; let depth = 0, cur = '';
    const push = () => { let t = cur.trim(); cur = ''; if (!t || t === '*') return;
      if (t.includes('(')) { const m = t.match(/^(?:\w+:)?(\w+)/); if (m) embeds.push(m[1]); return; }
      t = t.replace(/^\w+:/, '').replace(/::\w+$/, '').split(/->/)[0].trim();
      if (/^[A-Za-z_]\w*$/.test(t)) cols.push(t); };
    for (const c of s) { if (c === '(') depth++; if (c === ')') depth--; if (c === ',' && depth === 0) push(); else cur += c; }
    push(); return { cols, embeds };
  };
  const stripComments = (s) => {      // blank out comments, keeping offsets and line numbers
    const o = s.split('');
    for (let i = 0; i < s.length; i++) {
      const c = s[i];
      if (c === "'" || c === '"' || c === '`') { i = skipString(s, i); continue; }
      if (c === '/' && s[i + 1] === '/' && s[i - 1] !== ':') { while (i < s.length && s[i] !== '\n') o[i++] = ' '; i--; continue; }
      if (c === '/' && s[i + 1] === '*') { const e = s.indexOf('*/', i + 2), stop = e < 0 ? s.length : e + 2; for (; i < stop; i++) if (s[i] !== '\n') o[i] = ' '; i--; }
    }
    return o.join('');
  };
  const CRUD = /\.(select|insert|update|upsert|delete)\s*\(/;
  const reEsc = (s) => s.replace(/[$]/g, '\\$');

  for (const file of files) {
    let raw; try { raw = git('show', `${target}:${file}`); } catch { continue; }
    const src = stripComments(raw), added = addedLines(file), lineOf = lineIndex(src);
    const isAdded = (off) => added.has(lineOf(off)), at = (off) => `${file}:${lineOf(off)}`;
    const consts = {};
    for (const m of src.matchAll(/(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(['"`])([^'"`]*?)\2/g)) if (!m[3].includes('${')) consts[m[1]] = m[3];
    // Where a row written by .insert(x) / .update(x) / .upsert(x) comes from, when it isn't written right there:
    // object literals assigned or pushed to x, or returned by the function x was set from (one level), in this file.
    // Returns the offsets of their opening braces.
    const returnsOf = (fn) => {
      const out = [];
      for (const d of src.matchAll(new RegExp(`function\\s+${reEsc(fn)}\\s*\\(|(?:const|let|var)\\s+${reEsc(fn)}\\s*=`, 'g'))) {
        const head = src.slice(d.index, d.index + 300);
        const expr = head.match(/=>\s*\(\s*\{/);                       // (r) => ({ ... })
        const body = head.match(/(?:=>|\))\s*\{/);                     // (r) => { ... } or function f(r) { ... }
        if (expr && (!body || expr.index <= body.index)) { out.push(d.index + expr.index + expr[0].length - 1); break; }
        if (!body) continue;
        const open = d.index + body.index + body[0].length - 1, close = balanced(src, open);
        const inner = [];                                              // functions defined inside it return their own things
        for (const f of src.slice(open + 1, close).matchAll(/=>\s*\{|\bfunction\b[^{(]*\([^)]*\)\s*\{/g)) {
          const o = open + 1 + f.index + f[0].length - 1; inner.push([o, balanced(src, o)]);
        }
        for (const r of src.slice(open, close).matchAll(/\breturn\s*\(?\s*\{/g)) {
          const pos = open + r.index;
          if (!inner.some(([a, b]) => pos > a && pos < b)) out.push(open + r.index + r[0].length - 1);
        }
        break;
      }
      return out;
    };
    const literalsOf = (id, before) => {   // only the LAST assignment to id before the call, and pushes after it
      const v = reEsc(id), out = [];
      const defs = [...src.matchAll(new RegExp(`(?<![\\w$.])${v}\\s*=(?![=>])`, 'g'))].filter((d) => d.index < before);
      if (!defs.length) return out;
      const d = defs[defs.length - 1], rhs = src.slice(d.index + d[0].length, d.index + d[0].length + 200);
      let r;
      if ((r = /^\s*\[?\s*\{/.exec(rhs))) out.push(d.index + d[0].length + r[0].length - 1);
      else if ((r = /^\s*(?:await\s+)?([A-Za-z_$][\w$]*)\s*\(/.exec(rhs)) && !/\.map$/.test(r[1])) out.push(...returnsOf(r[1]));
      if ((r = /^[^;\n]{0,160}?=>\s*\(\s*\{/.exec(rhs))) out.push(d.index + d[0].length + r[0].length - 1);
      for (const p of src.matchAll(new RegExp(`(?<![\\w$.])${v}\\.push\\(\\s*\\{`, 'g')))
        if (p.index > d.index && p.index < before) out.push(p.index + p[0].length - 1);
      return [...new Set(out)];
    };

    for (const m of src.matchAll(/\.from\(\s*(?:(['"`])([\w-]+)\1|([A-Za-z_$][\w$.]*))\s*\)/g)) {
      const before = src.slice(Math.max(0, m.index - 40), m.index);
      const isStorage = /storage\s*$/.test(before);
      const seg = src.slice(m.index, chainEnd(src, m.index + m[0].length)), headAdded = isAdded(m.index);
      if (!isStorage && !CRUD.test(seg)) continue;      // Array.from('abc'), Buffer.from('x') and friends
      if (!m[2]) { if (headAdded) dynamic.push(`${at(m.index)} .from(${m[3]})`); continue; }
      if (isStorage) { if (headAdded) add({ k: 'bucket', n: m[2] }, at(m.index)); continue; }
      const t = m[2]; let any = headAdded;
      const colRef = (col, off) => { if (headAdded || isAdded(off)) { any = true; add({ k: 'column', t, n: col }, at(off)); } };
      for (const s of seg.matchAll(/\.select\(\s*(?:(['"`])([\s\S]*?)\1|([A-Za-z_$][\w$]*))/g)) {
        const off = m.index + s.index, str = s[2] ?? consts[s[3]];
        if (str === undefined) { if (headAdded || isAdded(off)) dynamic.push(`${at(off)} ${t}.select(${s[3]})`); continue; }
        const { cols, embeds } = selectCols(str);
        cols.forEach((c) => colRef(c, off));
        embeds.forEach((e) => { if (headAdded || isAdded(off)) add({ k: 'embed', t, n: e }, at(off)); });
      }
      for (const f of seg.matchAll(/\.(eq|neq|gt|gte|lt|lte|like|ilike|is|in|contains|containedBy|overlaps|order|not|filter|textSearch)\(\s*(['"`])([A-Za-z_][\w.]*)/g))
        if (!f[3].includes('.')) colRef(f[3], m.index + f.index);
      for (const f of seg.matchAll(/onConflict:\s*(['"`])([\w, ]+)\1/g)) f[2].split(',').forEach((c) => colRef(c.trim(), m.index + f.index));
      for (const w of seg.matchAll(/\.(update|insert|upsert)\(\s*\[?\s*\{/g)) {
        const open = m.index + w.index + w[0].length - 1, { keys, offs, spread } = topKeys(src.slice(open, balanced(src, open) + 1));
        keys.forEach((k, i) => colRef(k, open + offs[i]));
        if (spread && (headAdded || isAdded(open))) dynamic.push(`${at(open)} ${t}.${w[1]}({...spread})`);
      }
      for (const w of seg.matchAll(/\.(update|insert|upsert)\(/g)) {   // the row comes from somewhere else
        const paren = m.index + w.index + w[0].length - 1, arg = src.slice(paren + 1, balanced(src, paren));
        if (/^\s*\[?\s*\{/.test(arg)) continue;                          // written right here: done above
        const callAdded = headAdded || isAdded(paren);
        const id = arg.match(/^\s*\[?\s*([A-Za-z_$][\w$]*)\s*\]?\s*(?:,[\s\S]*)?$/);
        const arrow = /=>\s*\(\s*\{/.exec(arg);
        const objs = id ? literalsOf(id[1], paren) : arrow ? [paren + 1 + arrow.index + arrow[0].length - 1] : [];
        let spread = false;
        for (const open of objs) {
          const r = topKeys(src.slice(open, balanced(src, open) + 1)); spread = spread || r.spread;
          r.keys.forEach((k, i) => { const off = open + r.offs[i]; if (callAdded || isAdded(off)) colRef(k, callAdded ? paren : off); });
        }
        if (callAdded && (!objs.length || spread)) dynamic.push(`${at(paren)} ${t}.${w[1]}(${id ? id[1] : '...'}): its columns come from elsewhere`);
      }
      if (any) add({ k: 'table', n: t }, at(m.index));
    }
    for (const m of src.matchAll(/\.rpc\(\s*(?:(['"`])(\w+)\1|([A-Za-z_$][\w$.]*))/g)) {
      if (!m[2]) { if (isAdded(m.index)) dynamic.push(`${at(m.index)} .rpc(${m[3]})`); continue; }
      let args; const a = src.slice(m.index + m[0].length).match(/^\s*,\s*\{/);
      if (a) { const open = m.index + m[0].length + a[0].length - 1; args = topKeys(src.slice(open, balanced(src, open) + 1)).keys; }
      if (isAdded(m.index)) add({ k: 'rpc', n: m[2], args }, at(m.index));
    }
    for (const m of src.matchAll(/functions\.invoke\(\s*(?:(['"`])([\w-]+)\1|([A-Za-z_$][\w$.]*))|functions\/v1\/(?:([\w-]+)|\$\{([^}]+)\})/g)) {
      if (!isAdded(m.index)) continue;
      const name = m[2] || m[4];
      if (name) add({ k: 'edge', n: name }, at(m.index)); else dynamic.push(`${at(m.index)} edge function via ${m[3] || m[5]}`);
    }
  }

  const refs = [...out.values()].map(({ src, ...r }) => ({ ...r, src: src.join(' ') }));
  const by = (k) => refs.filter((r) => r.k === k).length;
  refs.filter((r) => r.k === 'edge').forEach((r) => console.log(`  EDGE     ${r.n}  (${r.src}): make sure this edge function is deployed`));
  dynamic.forEach((d) => console.log(`  DYNAMIC  ${d}: name built at runtime, read it yourself`));
  if (!refs.some((r) => r.k !== 'edge')) { console.log(`no database references on new lines in ${files.length} changed file(s): nothing to check`); process.exit(3); }
  if (!OUT) { process.stdout.write(JSON.stringify({ files: files.length, dynamic, refs })); process.exit(0); }
  writeFileSync(OUT, JSON.stringify({ files: files.length, dynamic, refs }));
  console.log(`${refs.length} database reference(s) on new lines in ${files.length} changed file(s): ` +
    ['table', 'column', 'embed', 'rpc', 'bucket', 'edge'].map((k) => `${k}=${by(k)}`).join(' '));
  process.exit(0);
} catch (e) {
  console.log('DATABASE CHECK DID NOT RUN: ' + (e.stderr ? String(e.stderr).trim() : e.message));
  process.exit(2);
}
