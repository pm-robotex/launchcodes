#!/usr/bin/env node
// cfg.mjs <repo> <key> [default]   — prints one value from <repo>/.claude/launchcodes.json (lists: one item per line)
// cfg.mjs <repo> --check           — validates the whole file
// Exit: 0 | 2 CONFIG_INVALID (printed on stdout, so a caller that captures the output can show it)
import { loadConfig, ConfigError, CONFIG_FILE } from './cfg_lib.mjs';

const [repo, key, def = ''] = process.argv.slice(2);
let cfg;
try { cfg = loadConfig(repo); }
catch (e) {
  if (e instanceof ConfigError) { console.log(`CONFIG_INVALID: ${CONFIG_FILE}: ${e.message}`); process.exit(2); }
  throw e;
}
if (key === '--check') { console.log('CONFIG_OK'); process.exit(0); }
const v = cfg[key];
process.stdout.write(v === undefined || v === null ? def : Array.isArray(v) ? v.join('\n') : String(v));
