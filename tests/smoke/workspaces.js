#!/usr/bin/env node
// Reproducible UX regression with invented data and blocked external requests.
// CHROMIUM_PATH=/usr/bin/chromium node workspaces.js
// Optional page substring arguments narrow the targets. No live writes or sends.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const { chromium } = require('playwright');
const fixtures = require('./fixtures');
const root = path.resolve(__dirname, '../..');
const stub = fs.readFileSync(path.join(__dirname, 'stub-supabase.js'), 'utf8');
const chart = fs.readFileSync(path.join(__dirname, 'node_modules/chart.js/dist/chart.umd.js'), 'utf8');
const filters = process.argv.slice(2).filter(arg => !arg.startsWith('--'));
const failuresOnly = process.argv.includes('--failures-only');
const targets = [
  ['dashboard', 'landlord', '#workspaceUpdated', 'Updated'],
  ['property-management', 'landlord', '#portfolioResults', 'Showing'],
  ['property-overview', 'landlord', '#heroName', 'Oak Street'],
  ['lease-rent-center', 'landlord', '#ledgerResults', 'rent periods'],
  ['maintenance-requests', 'landlord', '#maintenanceResults', 'in this view'],
  ['expense-tracking', 'landlord', '#expenseResults', 'in this view'],
  ['add-expense', 'landlord', '#propertySelect', 'Oak Street'],
  ['add-property', 'landlord', '.entry-guide-nav', 'Review'],
  ['lease-form', 'landlord', '.entry-guide-nav', 'Review'],
  ['tenant-portal', 'tenant', '#tenantBalance', '$'],
  ['tenant-repair-requests', 'tenant', '#tenantRepairResults', 'in this view'],
  ['tenant-payments', 'tenant', '#resultCount', 'payment'],
  ['tenant-documents', 'tenant', '#documentResults', 'in this view'],
  ['tenant-contact', 'tenant', '#messageResults', 'recent message']
].filter(([name]) => !filters.length || filters.some(filter => name.includes(filter)));
assert(targets.length, 'No matching workspaces; zero tests is not success');
const mime = {'.html':'text/html', '.js':'application/javascript', '.css':'text/css', '.json':'application/json', '.png':'image/png', '.svg':'image/svg+xml'};
const server = http.createServer((req, res) => {
  const file = path.resolve(root, '.' + new URL(req.url, 'http://test').pathname);
  if (!file.startsWith(root + path.sep) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {res.writeHead(404);res.end();return;}
  res.writeHead(200, {'Content-Type': mime[path.extname(file)] || 'application/octet-stream'});
  fs.createReadStream(file).pipe(res);
});
function sample(role) {
  const data = fixtures[role]();
  data.properties[0].occupancy_status = 'tenant_occupied';
  data.properties[1].occupancy_status = 'vacant';
  data.expenses.push({...data.expenses[0], id:99, amount:500, is_planned:true, vendor:'Planned vendor'});
  data.tenant_documents = [{id:1, tenant_id:data.tenants[0].id, tenant_email:'tenant@example.com', property_name:'Oak Street', title:'Signed lease', doc_type:'lease', created_at:new Date().toISOString()}];
  data.tenant_messages.push({...data.tenant_messages[0], id:2, sender:'landlord', subject:'Appointment', message:'<b>Literal text</b> ' + 'Please confirm access. '.repeat(20)});
  return data;
}
async function interactions(page, name) {
  if (name === 'dashboard') {
    await page.locator('.assistant-board-actions a[href="#manualMode"]').click();
    assert(await page.locator('#manualMode').evaluate(el => el.open), 'Reports expand through shortcut');
  } else if (name === 'property-management') {
    await page.locator('#searchInput').fill('Test Tenant');
    assert.equal(await page.locator('.portfolio-property').count(), 1);
    assert.equal(await page.locator('#kpiTotal').textContent(), '2', 'Portfolio total survives filtering');
    await page.locator('#searchInput').fill('no matching property');
    await page.getByRole('button', {name:'Reset filters'}).click();
    assert.equal(await page.locator('.portfolio-property').count(), 2);
  } else if (name === 'property-overview') {
    const href = await page.locator('[data-workspace-page="property-documents.html"]').getAttribute('href');
    assert(href.includes('property_id=') && href.includes('company_id='), 'Property context preserved');
  } else if (name === 'lease-rent-center') {
    for (const mode of ['paid', 'upcoming', 'outstanding', 'all']) {
      await page.locator('#ledgerView').selectOption(mode);
      assert(await page.locator('#dueLedgerBody tr[data-period]').evaluateAll((rows, view) => rows.every(row => row.hidden === (view !== 'all' && row.dataset[view] !== 'true')), mode));
    }
    await page.locator('#tabBtnRent').focus();await page.keyboard.press('ArrowRight');
    assert.equal(await page.locator('#tabBtnLease').getAttribute('aria-selected'), 'true');
  } else if (name === 'maintenance-requests') {
    await page.locator('[data-chip="unassigned"]').click();
    await page.waitForFunction(() => document.getElementById('maintenanceResults').textContent.startsWith('0 repair'));
    await page.locator('#resetMaintenanceFilters').click();
    await page.waitForFunction(() => document.getElementById('maintenanceResults').textContent.startsWith('1 repair'));
    await page.locator('.maintenance-plan-btn').click();
    assert.equal(await page.locator('#edit_assigned_vendor').inputValue(), 'Ace Plumbing');
    await page.keyboard.press('Escape');
    assert(await page.locator('.maintenance-plan-btn').evaluate(el => el === document.activeElement));
  } else if (name === 'expense-tracking') {
    assert((await page.locator('#totalExpenses').textContent()).includes('240.00'));
    await page.locator('#expenseKind').selectOption('planned');
    await page.waitForFunction(() => document.getElementById('totalExpenses').textContent.includes('500.00'));
  } else if (name === 'add-expense') {
    await page.locator('#snapFile').focus();
    assert(await page.locator('#snapFile').evaluate(el => el === document.activeElement));
  } else if (['add-property','lease-form'].includes(name)) {
    const id = name === 'add-property' ? 'propertyName' : 'tenantName';
    await page.locator('#' + id).fill('<b>Literal test</b>');
    await page.locator('.entry-guide-nav').getByRole('link',{name:'Review',exact:true}).click();
    assert((await page.locator('#entryReview').innerText()).includes('<b>Literal test</b>'));
    assert.equal(await page.locator('#entryReview b').count(), 0);
  } else if (name === 'tenant-repair-requests') {
    await page.locator('#tenantRepairView').selectOption('resolved');
    await page.waitForFunction(() => document.getElementById('tenantRepairResults').textContent.startsWith('0 request'));
  } else if (name === 'tenant-documents') {
    await page.locator('#documentType').selectOption('receipt');
    await page.waitForFunction(() => document.getElementById('documentResults').textContent.startsWith('0 document'));
  } else if (name === 'tenant-contact') {
    await page.locator('#messageSearch').fill('Appointment');
    await page.locator('#msgHistory summary').click();
    assert((await page.locator('#msgHistory details p').textContent()).startsWith('<b>Literal text</b>'));
  } else if (name === 'tenant-payments') {
    await page.locator('#search').fill('no matching payment');
    await page.waitForFunction(() => document.getElementById('resultCount').textContent === '0 payments');
  }
}
(async () => {
  let browser, checks = 0;
  try {
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const origin = 'http://127.0.0.1:' + server.address().port;
    browser = await chromium.launch(process.env.CHROMIUM_PATH ? {executablePath:process.env.CHROMIUM_PATH} : {});
    for (const [name, role, ready, text] of (failuresOnly ? [] : targets)) for (const width of [320,390,768,1920,2560]) {
      const context = await browser.newContext({viewport:{width,height:1000}, reducedMotion:'reduce'});
      const page = await context.newPage(), errors = [];
      page.on('pageerror', error => errors.push(error.message));
      const data = sample(role);
      await page.route('**/*', route => {
        const url = route.request().url();
        if (url.startsWith(origin)) return route.continue();
        if (url.includes('supabase-js@2')) return route.fulfill({contentType:'application/javascript',body:'window.__RG_FIXTURE=' + JSON.stringify(data) + ';\n' + stub});
        if (url.includes('chart.js@')) return route.fulfill({contentType:'application/javascript',body:chart});
        if (url.includes('fonts.googleapis.com')) return route.fulfill({contentType:'text/css',body:''});
        return route.abort();
      });
      await page.goto(origin + '/' + name + '.html?property=Oak%20Street&property_id=' + data.properties[0].id + '&company_id=' + data.companies[0].id);
      await page.waitForFunction(({selector, expected}) => document.querySelector(selector)?.textContent.includes(expected), {selector:ready,expected:text});
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), name + ': page overflow at ' + width);
      if (width >= 1920) assert(await page.locator('main').evaluate(el => Math.abs(el.getBoundingClientRect().width - innerWidth) <= 2), name + ': desktop width capped');
      if (role === 'tenant') {
        assert.equal(await page.locator('.tenant-resource-nav a[aria-current="page"]').count(), 1);
        assert((await page.locator('.tenant-resource-nav a').first().getAttribute('href')).includes('property=Oak+Street'));
      }
      await interactions(page, name);
      assert.deepEqual(errors, [], name + ': JavaScript errors');
      checks++;
      console.log('PASS ' + name + ' ' + width);
      await context.close();
    }
    // Unavailable data must never masquerade as an empty/paid portfolio.
    const failures = [
      ['property-management','landlord','rpc','rg_rent_status','#propertyCards','Unavailable'],
      ['maintenance-requests','landlord','from','maintenance_requests','#maintenanceResults','Requests unavailable'],
      ['expense-tracking','landlord','from','expenses','#expenseResults','Expenses unavailable'],
      ['tenant-portal','tenant','rpc','rg_my_rent_schedule','#tenantBalance','Unavailable'],
      ['tenant-payments','tenant','rpc','rg_my_rent_schedule','#paidThisMonth','Unavailable'],
      ['tenant-documents','tenant','from','tenant_documents','#documentResults','Documents unavailable'],
      ['tenant-contact','tenant','from','tenant_messages','#messageResults','Message history unavailable']
    ].filter(([name]) => targets.some(target => target[0] === name));
    for (const [name, role, method, failedName, selector, expected] of failures) {
      const context = await browser.newContext({viewport:{width:390,height:900}});
      const page = await context.newPage(), data = sample(role), errors=[];
      page.on('pageerror', error => errors.push(error.message));
      const override = `;(function(){var create=window.supabase.createClient;window.supabase.createClient=function(){var c=create.apply(this,arguments),original=c[${JSON.stringify(method)}].bind(c);c[${JSON.stringify(method)}]=function(name,args){if(name!==${JSON.stringify(failedName)})return original(name,args);var failure={error:{message:'Simulated service outage'}};if(${JSON.stringify(method)}==='rpc')return Promise.resolve(failure);var q=original(name,args);q.then=function(resolve,reject){return Promise.resolve(failure).then(resolve,reject)};return q};return c}})();`;
      await page.route('**/*', route => {
        const url=route.request().url();
        if(url.startsWith(origin))return route.continue();
        if(url.includes('supabase-js@2'))return route.fulfill({contentType:'application/javascript',body:'window.__RG_FIXTURE='+JSON.stringify(data)+';\n'+stub+override});
        if(url.includes('chart.js@'))return route.fulfill({contentType:'application/javascript',body:chart});
        if(url.includes('fonts.googleapis.com'))return route.fulfill({contentType:'text/css',body:''});
        return route.abort();
      });
      await page.goto(origin+'/'+name+'.html?property=Oak%20Street');
      await page.waitForFunction(({selector,expected})=>document.querySelector(selector)?.textContent.includes(expected),{selector,expected});
      assert.deepEqual(errors,[],name+': failure handling threw');
      console.log('PASS '+name+' unavailable-data handling');checks++;
      await context.close();
    }
    console.log(checks + ' workspace checks passed. External services were stubbed.');
  } finally {
    if (browser) await browser.close();
    server.close();
  }
})().catch(error => {console.error(error);process.exitCode=1;});
