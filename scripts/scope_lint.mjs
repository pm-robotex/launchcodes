#!/usr/bin/env node
// scope_lint.mjs <repo> <base-rev> <target-rev> [eslint-dir]
// Catches the "green build, white screen" bug: a JS/JSX file that uses a name nothing defines. Bundlers don't
// check this in .js/.jsx, so a component used with no import, or a variable read in a sibling component that
// never received it, builds fine and crashes in the browser. ESLint's own `no-undef` does NOT see JSX element
// names, so this adds a small rule that does.
//
// Lints every .js/.jsx/.mjs file ADDED or MODIFIED between <base> and <target>, as committed at <target> (read
// from git, never from your working folder). Each file is also linted as it was at <base>, and only NEW errors
// count, so old problems don't block an unrelated change. TypeScript files are left to your build's type check.
// ESLint (8.57+ or 9) is loaded from <eslint-dir> (the clean copy, after its install) or else from <repo>.
// Exit: 0 pass | 1 NEW errors | 2 did not run (never read as a pass) | 3 skipped (no usable ESLint) | 4 nothing to lint
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { loadConfig } from './cfg_lib.mjs';

// Same job as eslint-plugin-react's jsx-no-undef: the root name of every JSX element must be declared in an
// enclosing scope or be a configured global. Lowercase plain tags (<div>) are HTML.
const jsxNoUndef = {
  meta: { type: 'problem', schema: [] },
  create(context) {
    return {
      JSXOpeningElement(node) {
        let id = node.name;
        const member = id.type === 'JSXMemberExpression';
        while (id.type === 'JSXMemberExpression') id = id.object;
        if (id.type !== 'JSXIdentifier') return;
        if (!member && !/^[A-Z_$]/.test(id.name)) return;
        const sc = context.sourceCode ?? context.getSourceCode();
        for (let s = sc.getScope ? sc.getScope(node) : context.getScope(); s; s = s.upper) if (s.set.has(id.name)) return;
        context.report({ node: id, message: `'${id.name}' is not defined (used as a JSX component).` });
      },
    };
  },
};

const FALLBACK_GLOBALS = ['window', 'document', 'console', 'process', 'fetch', 'setTimeout', 'clearTimeout', 'setInterval',
  'clearInterval', 'requestAnimationFrame', 'cancelAnimationFrame', 'queueMicrotask', 'structuredClone', 'localStorage',
  'sessionStorage', 'navigator', 'location', 'history', 'screen', 'performance', 'alert', 'confirm', 'prompt', 'URL',
  'URLSearchParams', 'Blob', 'File', 'FileReader', 'FormData', 'Headers', 'Request', 'Response', 'AbortController',
  'Event', 'CustomEvent', 'TextEncoder', 'TextDecoder', 'crypto', 'atob', 'btoa', 'Image', 'Audio', 'WebSocket', 'Worker',
  'getComputedStyle', 'matchMedia', 'IntersectionObserver', 'ResizeObserver', 'MutationObserver', 'HTMLElement',
  'customElements', 'self', 'globalThis', 'module', 'require', 'exports', '__dirname', '__filename', 'Buffer'];

try {
  const [repo, base, target, eslintDir] = process.argv.slice(2);
  if (!repo || !base || !target) throw new Error('usage: scope_lint.mjs <repo> <base> <target> [eslint-dir]');
  const git = (...a) => execFileSync('git', ['-c', 'core.quotePath=false', '-C', repo, ...a],
    { encoding: 'utf8', maxBuffer: 1 << 28, stdio: ['pipe', 'pipe', 'pipe'] });
  const skip = /(^|\/)(node_modules|dist|build|out|\.next|coverage|vendor)\/|\.min\.js$|\.(test|spec)\.[jt]sx?$|(^|\/)__tests__\//;
  const files = git('diff', '--name-only', '-z', '--no-renames', '--diff-filter=AM', base, target)
    .split('\0').filter((f) => /\.(jsx?|mjs)$/.test(f) && !skip.test(f));
  if (!files.length) { console.log('nothing to code-check: no changed .js/.jsx/.mjs files'); process.exit(4); }

  let req, eslintMod;
  for (const d of [eslintDir, repo].filter(Boolean)) {
    try { const r = createRequire(join(d, 'package.json')); eslintMod = r('eslint'); req = r; break; } catch { /* try the next folder */ }
  }
  if (!eslintMod) { console.log('ESLINT_NOT_INSTALLED — code check skipped (add eslint 9 as a dev dependency to turn it on)'); process.exit(3); }
  const ver = String(eslintMod.ESLint?.version || eslintMod.Linter?.version || '0.0');
  const [maj, min] = ver.split('.').map(Number);
  let EslintClass = eslintMod.ESLint;
  if (maj < 9) {
    try { EslintClass = req('eslint/use-at-your-own-risk').FlatESLint; } catch { EslintClass = undefined; }
    if (!EslintClass || maj < 8 || (maj === 8 && min < 57)) {
      console.log(`ESLINT_UNSUPPORTED — ESLint ${ver} is too old for the code check (it needs 8.57 or 9); skipped`); process.exit(3);
    }
  }
  const eslintReq = createRequire(req.resolve('eslint'));
  let globals = {};
  try { const gl = eslintReq('globals'); globals = { ...gl.browser, ...gl.node, ...gl.serviceworker }; }
  catch { for (const n of FALLBACK_GLOBALS) globals[n] = 'readonly'; }
  for (const n of loadConfig(repo).lintGlobals || []) globals[n] = 'readonly';
  const plugins = { launchcodes: { rules: { 'jsx-no-undef': jsxNoUndef } } };
  const rules = { 'no-undef': 'error', 'launchcodes/jsx-no-undef': 'error' };
  try { plugins['react-hooks'] = req('eslint-plugin-react-hooks'); rules['react-hooks/rules-of-hooks'] = 'error'; } catch { /* optional */ }
  const eslint = new EslintClass({
    cwd: repo,
    overrideConfigFile: true,
    overrideConfig: [{
      files: ['**/*.{js,jsx,mjs}'],
      languageOptions: { ecmaVersion: 'latest', sourceType: 'module', parserOptions: { ecmaFeatures: { jsx: true } }, globals },
      plugins, rules,
    }],
  });

  const blobs = (rev) => {
    const buf = execFileSync('git', ['-C', repo, 'cat-file', '--batch'], { input: files.map((f) => `${rev}:${f}`).join('\n') + '\n', maxBuffer: 1 << 30 });
    const out = new Map(); let p = 0;
    for (const f of files) {
      const nl = buf.indexOf(10, p); const hdr = buf.slice(p, nl).toString(); p = nl + 1;
      if (hdr.endsWith('missing')) continue;
      const size = Number(hdr.split(' ')[2]); out.set(f, buf.slice(p, p + size).toString('utf8')); p += size + 1;
    }
    return out;
  };
  const errorsOf = async (text, f) => {
    const [r] = await eslint.lintText(text, { filePath: join(repo, f) });
    return r.messages.filter((m) => m.severity === 2 || m.fatal);
  };
  const key = (f, m) => `${f}|${m.ruleId || 'parse'}|${m.message}`;
  const now = blobs(target), before = blobs(base);
  let linted = 0, preexisting = 0; const fresh = [];
  for (const f of files) {
    const text = now.get(f); if (text === undefined) continue;
    const errs = await errorsOf(text, f); linted++;
    const had = new Map();
    if (before.has(f)) for (const m of await errorsOf(before.get(f), f)) had.set(key(f, m), (had.get(key(f, m)) || 0) + 1);
    for (const m of errs) {
      const k = key(f, m);
      if ((had.get(k) || 0) > 0) { had.set(k, had.get(k) - 1); preexisting++; }
      else fresh.push(`${f}:${m.line}  ${m.ruleId || 'parse-error'}  ${m.message}`);
    }
  }
  console.log(`code check: ${linted} of ${files.length} file(s) with ESLint ${ver}; ${fresh.length} NEW error(s); ${preexisting} older ones (already there before, not blocking)`);
  fresh.forEach((l) => console.log('  NEW ' + l));
  if (fresh.length) console.log('Each NEW error builds fine and crashes in the browser. If one names a global your page gets from a <script> tag or a bundler define, add it to "lintGlobals" in .claude/launchcodes.json.');
  process.exit(linted !== files.length ? 2 : fresh.length ? 1 : 0);
} catch (e) {
  console.log('CODE CHECK DID NOT RUN: ' + (e.stderr ? String(e.stderr).trim() : e.message));
  process.exit(2);
}
