#!/usr/bin/env node
// Smoke test for every page: load it at a phone and a desktop width with a stubbed Supabase client
// and fail on an uncaught JavaScript error, a page that never finishes loading, or sideways
// scrolling. Console errors, same-origin 404s and alert() dialogs are reported as warnings.
//
//   cd tests/smoke && npm ci && npx playwright install chromium   (once)
//   node run.js                       every page
//   node run.js dashboard tenant-     only pages whose file name contains one of the words
//
// CHROMIUM_PATH=/path/to/chromium uses an existing browser instead of Playwright's download.
// Screenshots of failing pages go to tests/smoke/artifacts/.

const fs = require('fs');
const path = require('path');
const http = require('http');
const { chromium } = require('playwright');
const fixtures = require('./fixtures');

const ROOT = path.resolve(__dirname, '..', '..');
const ARTIFACTS = path.join(__dirname, 'artifacts');
const STUB = fs.readFileSync(path.join(__dirname, 'stub-supabase.js'), 'utf8');
const CHART = fs.readFileSync(path.join(__dirname, 'node_modules', 'chart.js', 'dist', 'chart.umd.js'), 'utf8');
const WIDTHS = [{ name: 'phone', width: 390, height: 844 }, { name: 'desktop', width: 1280, height: 900 }];
const SETTLE_MS = 1500;
// Public pages also get a signed-out pass
const PUBLIC = ['index.html', 'listings.html', 'login.html', 'signup.html', 'forgot-password.html', 'contact-us.html', 'privacy.html', 'terms.html'];

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'application/javascript', '.css': 'text/css', '.json': 'application/json',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.webp': 'image/webp' };

function serve() {
  const server = http.createServer((req, res) => {
    const rel = decodeURIComponent(new URL(req.url, 'http://x').pathname).replace(/^\/+/, '') || 'index.html';
    const file = path.join(ROOT, rel);
    if (!file.startsWith(ROOT) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) { res.writeHead(404); res.end('not found'); return; }
    res.writeHead(200, { 'Content-Type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream' });
    fs.createReadStream(file).pipe(res);
  });
  return new Promise(resolve => server.listen(0, '127.0.0.1', () => resolve(server)));
}

function roleFor(page) {
  if (page === 'my-applications.html') return 'tenant';
  if (page.startsWith('tenant-') && page !== 'tenant-portal-picker.html') return 'tenant';
  return 'landlord';
}

async function check(browser, origin, page, role, vp) {
  const fixture = fixtures[role]();
  const ctx = await browser.newContext({ viewport: { width: vp.width, height: vp.height } });
  const tab = await ctx.newPage();
  const errors = [], warnings = [];
  tab.on('pageerror', e => errors.push('Uncaught: ' + (e && e.message ? e.message : String(e)).split('\n')[0]));
  tab.on('console', m => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) warnings.push('console.error: ' + m.text().slice(0, 200)); });
  tab.on('dialog', d => { warnings.push('dialog: ' + d.message().slice(0, 120)); d.dismiss().catch(() => {}); });
  tab.on('response', r => { if (r.url().startsWith(origin) && r.status() >= 400) warnings.push(r.status() + ' ' + r.url().slice(origin.length)); });

  await tab.route('**/*', route => {
    const url = route.request().url();
    if (url.startsWith(origin)) return route.continue();
    if (/supabase-js@2/.test(url)) return route.fulfill({ contentType: 'application/javascript', body: 'window.__RG_FIXTURE=' + JSON.stringify(fixture) + ';\n' + STUB });
    if (/chart\.js@[^/]+\/dist\/chart\.umd(\.min)?\.js/.test(url)) return route.fulfill({ contentType: 'application/javascript', body: CHART });
    if (/fonts\.googleapis\.com/.test(url)) return route.fulfill({ contentType: 'text/css', body: '' });
    return route.abort();   // fonts.gstatic, the Supabase project URL, anything else external
  });

  let overflow = 0, finalUrl = '';
  try {
    await tab.goto(origin + '/' + page, { waitUntil: 'load', timeout: 20000 });
    await tab.waitForTimeout(SETTLE_MS);
    await tab.waitForLoadState('load', { timeout: 10000 });
    finalUrl = tab.url().slice(origin.length);
    overflow = await tab.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    if (overflow > 1) errors.push('Scrolls sideways by ' + overflow + 'px');
  } catch (e) {
    errors.push('Did not finish loading: ' + String(e.message || e).split('\n')[0]);
  }
  if (errors.length) {
    fs.mkdirSync(ARTIFACTS, { recursive: true });
    await tab.screenshot({ path: path.join(ARTIFACTS, page.replace(/\.html$/, '') + '-' + role + '-' + vp.name + '.png'), fullPage: true }).catch(() => {});
  }
  await ctx.close();
  return { page, role, width: vp.name, finalUrl, errors, warnings: [...new Set(warnings)] };
}

(async () => {
  const filters = process.argv.slice(2);
  const pages = fs.readdirSync(ROOT).filter(f => f.endsWith('.html')).sort()
    .filter(p => !filters.length || filters.some(w => p.includes(w)));
  const runs = [];
  for (const p of pages) {
    runs.push([p, roleFor(p)]);
    if (PUBLIC.includes(p)) runs.push([p, 'guest']);
  }

  const server = await serve();
  const origin = 'http://127.0.0.1:' + server.address().port;
  const browser = await chromium.launch(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {});
  const results = [];
  for (const [p, role] of runs) {
    for (const vp of WIDTHS) {
      const r = await check(browser, origin, p, role, vp);
      results.push(r);
      const mark = r.errors.length ? 'FAIL' : (r.warnings.length ? 'warn' : ' ok ');
      console.log(`${mark}  ${p} (${role}, ${vp.name})${r.finalUrl && !r.finalUrl.startsWith('/' + p) ? ' -> ' + r.finalUrl : ''}`);
      r.errors.forEach(e => console.log('        ✖ ' + e));
      r.warnings.forEach(w => console.log('        · ' + w));
    }
  }
  await browser.close();
  server.close();

  const failed = results.filter(r => r.errors.length);
  const warned = results.filter(r => !r.errors.length && r.warnings.length);
  console.log(`\n${results.length} checks, ${failed.length} failed, ${warned.length} with warnings.`);

  if (process.env.GITHUB_STEP_SUMMARY) {
    const lines = ['## Page smoke test', '', `${results.length} checks (${pages.length} pages × phone and desktop), **${failed.length} failed**, ${warned.length} with warnings.`, ''];
    if (failed.length) {
      lines.push('| Page | Signed in as | Width | Problem |', '|---|---|---|---|');
      failed.forEach(r => r.errors.forEach(e => lines.push(`| ${r.page} | ${r.role} | ${r.width} | ${e.replace(/\|/g, '\\|')} |`)));
      lines.push('', 'Screenshots are in the `smoke-screenshots` artifact.');
    }
    if (warned.length) {
      lines.push('', '<details><summary>Warnings (don\'t fail the check)</summary>', '');
      warned.forEach(r => r.warnings.forEach(w => lines.push(`- ${r.page} (${r.role}, ${r.width}): ${w.replace(/</g, '&lt;')}`)));
      lines.push('', '</details>');
    }
    fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, lines.join('\n') + '\n');
  }
  process.exit(failed.length ? 1 : 0);
})().catch(e => { console.error(e); process.exit(2); });
