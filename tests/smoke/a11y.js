#!/usr/bin/env node
// Automated accessibility check (axe-core, WCAG 2.1 A and AA rules) on the landlord and tenant
// workspaces at a phone and a desktop width, with the same stubbed Supabase client as run.js.
// Fails on any "critical" or "serious" violation; "moderate" and "minor" ones are listed.
//
//   node a11y.js                 every page below
//   node a11y.js dashboard       only pages whose file name contains one of the words
//   node a11y.js --all           report every impact level as a failure (for a full audit)
//   node a11y.js --colors        print the colour pair and ratio for each contrast failure
//
// Automated rules catch roughly a third of accessibility problems. They don't replace a screen
// reader, keyboard-only use, text zoom or a real phone; see docs/PRODUCT-UX-HANDOFF.md.

const fs = require('fs');
const path = require('path');
const http = require('http');
const { chromium } = require('playwright');
const AxeBuilder = require('@axe-core/playwright').default;
const fixtures = require('./fixtures');

const ROOT = path.resolve(__dirname, '..', '..');
const STUB = fs.readFileSync(path.join(__dirname, 'stub-supabase.js'), 'utf8');
const CHART = fs.readFileSync(path.join(__dirname, 'node_modules', 'chart.js', 'dist', 'chart.umd.js'), 'utf8');
const WIDTHS = [{ name: 'phone', width: 390, height: 844 }, { name: 'desktop', width: 1280, height: 900 }];
const PAGES = [
  ['dashboard.html', 'landlord'], ['property-management.html', 'landlord'], ['property-overview.html', 'landlord'],
  ['lease-rent-center.html', 'landlord'], ['maintenance-requests.html', 'landlord'], ['expense-tracking.html', 'landlord'],
  ['add-expense.html', 'landlord'], ['add-property.html', 'landlord'], ['lease-form.html', 'landlord'],
  ['reports-analytics.html', 'landlord'], ['account.html', 'landlord'],
  ['tenant-portal.html', 'tenant'], ['tenant-repair-requests.html', 'tenant'], ['tenant-payments.html', 'tenant'],
  ['tenant-documents.html', 'tenant'], ['tenant-contact.html', 'tenant'], ['tenant-account.html', 'tenant'],
  ['login.html', 'guest'], ['index.html', 'guest'], ['listings.html', 'guest'],
];
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'application/javascript', '.css': 'text/css',
  '.json': 'application/json', '.png': 'image/png', '.svg': 'image/svg+xml', '.ico': 'image/x-icon' };

function serve() {
  const server = http.createServer((req, res) => {
    const rel = decodeURIComponent(new URL(req.url, 'http://x').pathname).replace(/^\/+/, '') || 'index.html';
    const file = path.join(ROOT, rel);
    if (!file.startsWith(ROOT) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { 'Content-Type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream' });
    fs.createReadStream(file).pipe(res);
  });
  return new Promise(resolve => server.listen(0, '127.0.0.1', () => resolve(server)));
}

(async () => {
  const args = process.argv.slice(2);
  const strictAll = args.includes('--all');
  const showColors = args.includes('--colors');
  const words = args.filter(a => !a.startsWith('--'));
  const pages = PAGES.filter(([p]) => !words.length || words.some(w => p.includes(w)));
  if (!pages.length) { console.error('No page matches ' + words.join(', ')); process.exit(2); }

  const server = await serve();
  const origin = 'http://127.0.0.1:' + server.address().port;
  const browser = await chromium.launch(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {});
  const failing = strictAll ? ['critical', 'serious', 'moderate', 'minor'] : ['critical', 'serious'];
  let failures = 0;
  const byRule = new Map();

  for (const [page, role] of pages) {
    for (const vp of WIDTHS) {
      // Reduced motion: the home page's demo cycles forever, and a scan mid-fade reports half-transparent text.
      const ctx = await browser.newContext({ viewport: { width: vp.width, height: vp.height }, reducedMotion: 'reduce' });
      const tab = await ctx.newPage();
      const fixture = fixtures[role]();
      await tab.route('**/*', route => {
        const url = route.request().url();
        if (url.startsWith(origin)) return route.continue();
        if (/supabase-js@2/.test(url)) return route.fulfill({ contentType: 'application/javascript', body: 'window.__RG_FIXTURE=' + JSON.stringify(fixture) + ';\n' + STUB });
        if (/chart\.js@[^/]+\/dist\/chart\.umd(\.min)?\.js/.test(url)) return route.fulfill({ contentType: 'application/javascript', body: CHART });
        if (/fonts\.googleapis\.com/.test(url)) return route.fulfill({ contentType: 'text/css', body: '' });
        return route.abort();
      });
      tab.on('dialog', d => d.dismiss().catch(() => {}));
      let violations = [];
      try {
        await tab.goto(origin + '/' + page, { waitUntil: 'load', timeout: 20000 });
        await tab.waitForTimeout(1500);
        const res = await new AxeBuilder({ page: tab }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
        violations = res.violations;
      } catch (e) {
        violations = [{ id: 'page-did-not-load', impact: 'critical', help: String(e.message || e).split('\n')[0], nodes: [] }];
      }
      const bad = violations.filter(v => failing.includes(v.impact));
      failures += bad.length;
      console.log(`${bad.length ? 'FAIL' : (violations.length ? 'warn' : ' ok ')}  ${page} (${role}, ${vp.name})`);
      for (const v of violations) {
        const mark = failing.includes(v.impact) ? '✖' : '·';
        const where = v.nodes.slice(0, 3).map(n => n.target.join(' ')).join(' | ');
        console.log(`        ${mark} [${v.impact}] ${v.id}: ${v.help} (${v.nodes.length}) ${where}`);
        if (showColors && v.id === 'color-contrast') v.nodes.forEach(n => {
          const d = (n.any[0] || {}).data || {};
          console.log(`            ${d.fgColor} on ${d.bgColor} = ${d.contrastRatio}:1 (needs ${d.expectedContrastRatio}) ${n.target.join(' ')}`);
        });
        const k = v.impact + ' ' + v.id;
        byRule.set(k, (byRule.get(k) || 0) + v.nodes.length);
      }
      await ctx.close();
    }
  }
  await browser.close();
  server.close();

  console.log('\nBy rule (elements affected, all pages and widths):');
  [...byRule.entries()].sort((a, b) => b[1] - a[1]).forEach(([k, n]) => console.log('  ' + n + '  ' + k));
  console.log(`\n${pages.length * WIDTHS.length} page checks, ${failures} failing violation(s) (${failing.join(', ')}).`);
  process.exit(failures ? 1 : 0);
})().catch(e => { console.error(e); process.exit(2); });
