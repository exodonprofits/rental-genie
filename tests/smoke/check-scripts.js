#!/usr/bin/env node
// Syntax-check every inline <script> in the top-level pages with `node --check` (CLAUDE.md:
// "Syntax-check inline scripts after editing a page"). JSON-LD and other non-JavaScript script
// types are skipped. Exits 1 if any script fails to parse.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'rg-scripts-'));
let bad = 0, checked = 0;

for (const page of fs.readdirSync(ROOT).filter(f => f.endsWith('.html')).sort()) {
  const html = fs.readFileSync(path.join(ROOT, page), 'utf8');
  const re = /<script\b([^>]*)>([\s\S]*?)<\/script>/gi;
  let m, n = 0;
  while ((m = re.exec(html))) {
    const attrs = m[1];
    if (/\bsrc\s*=/.test(attrs)) continue;
    const type = (attrs.match(/\btype\s*=\s*["']?([^"'\s>]+)/i) || [])[1];
    if (type && !/^(text|application)\/javascript$|^module$/i.test(type)) continue;
    const file = path.join(tmp, `${page}.${n++}.${type === 'module' ? 'mjs' : 'js'}`);
    fs.writeFileSync(file, m[2]);
    checked++;
    try {
      execFileSync(process.execPath, ['--check', file], { stdio: 'pipe' });
    } catch (e) {
      bad++;
      const line = html.slice(0, m.index).split('\n').length;
      console.log(`✖ ${page}: inline script starting at line ${line}\n${String(e.stderr).split('\n').slice(0, 5).join('\n')}`);
    }
  }
}
fs.rmSync(tmp, { recursive: true, force: true });
console.log(`${checked} inline scripts checked, ${bad} with syntax errors.`);
process.exit(bad ? 1 : 0);
