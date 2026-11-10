/* Rental Genie: tenant-side data helpers shared by the tenant pages (portal, payments, lease,
   repairs, documents, contact). Plain functions on window.rgTenant; no page state, no DOM.

   Why these exist (each was a bug on more than one page):
   - Lease dates are calendar dates. new Date('2026-02-01') is UTC midnight, which shows as Jan 31
     anywhere in the US: parseDay/fmtDate read 'YYYY-MM-DD' as a local date.
   - The rent schedule (rg_my_rent_schedule -> rg_rent_schedule) keeps one lease per property: the
     newest one started by "as of". Asking as of a future date drops the current lease as soon as a
     renewal or the next tenant's lease starts, so balances are read as of today and a second call
     (as of the end of next month) only supplies the next due date for the same lease.
   - The current lease is the one the schedule uses; otherwise the newest non-archived, non-draft
     lease; drafts only when nothing else exists. Never an archived lease.
   - A tenant's rows match their tenants.id OR their email (a lease can be missing tenant_id), the
     same rule the database's row-level security and the schedule use.
   - ?property_id= wins over ?property= (names change when a property is renamed); a name that no
     longer matches anything falls back to all of the tenant's leases instead of an empty page. */
(function () {
  function pad(n) { return String(n).padStart(2, '0'); }
  function ymd(d) { return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()); }
  function parseDay(iso) {
    var m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(iso || ''));
    return m ? new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3])) : null;
  }
  // Calendar dates (YYYY-MM-DD) as local dates; anything else (timestamps) through Date as usual.
  function fmtDate(v, opts) {
    if (!v) return '—';
    var d = /^\d{4}-\d{2}-\d{2}$/.test(String(v)) ? parseDay(v) : new Date(v);
    if (!d || isNaN(d.getTime())) return String(v);
    return d.toLocaleDateString(undefined, opts || { year: 'numeric', month: 'short', day: '2-digit' });
  }
  function today() { return ymd(new Date()); }
  // Whole days from today to a calendar date (0 = today, negative = past)
  function daysUntil(iso) {
    var d = parseDay(iso); if (!d) return NaN;
    var t = parseDay(today());
    return Math.round((d - t) / 86400000);
  }

  // PostgREST filter: this tenant's rows by tenant id or email (quoted: emails can hold reserved chars)
  function mine(q, tenant, email) {
    var e = String(email || '').replace(/"/g, '');
    if (tenant && tenant.id && e) return q.or('tenant_id.eq.' + tenant.id + ',tenant_email.ilike."' + e + '"');
    if (tenant && tenant.id) return q.eq('tenant_id', tenant.id);
    return q.ilike('tenant_email', e);
  }

  // Rent schedule rows: { today: rows as of today (balances), ahead: rows as of the end of next month }
  function schedule(sb) {
    var now = new Date();
    var ahead = ymd(new Date(now.getFullYear(), now.getMonth() + 2, 0));
    function call(asOf) {
      return sb.rpc('rg_my_rent_schedule', { p_as_of: asOf })
        .then(function (r) { return r.error ? null : (r.data || []); })
        .catch(function () { return null; });
    }
    return Promise.all([call(today()), call(ahead)]).then(function (res) {
      return { today: res[0], ahead: res[1], failed: res[0] === null };
    });
  }

  // Leases narrowed by the URL: property_id first, then name; nothing matching -> all leases
  function forUrl(leases, propertyName, propertyId) {
    leases = leases || [];
    if (propertyId) {
      var byId = leases.filter(function (l) { return l.property_id === propertyId; });
      if (byId.length) return byId;
    }
    if (propertyName) {
      var byName = leases.filter(function (l) { return l.property_name === propertyName; });
      if (byName.length) return byName;
    }
    return leases;
  }

  // The lease to show as current (see the header comment)
  function pickLease(leases, sched) {
    leases = (leases || []).filter(function (l) { return !l.archived_at; });
    if (!leases.length) return null;
    var inSchedule = {};
    (sched && sched.today || []).forEach(function (r) { inSchedule[r.lease_id] = true; });
    var byStart = leases.slice().sort(function (a, b) { return String(b.lease_start || '') < String(a.lease_start || '') ? -1 : 1; });
    var isDraft = function (l) { return String(l.status || '').toLowerCase() === 'draft'; };
    var t = today();
    return byStart.filter(function (l) { return inSchedule[l.id]; })[0]
      || byStart.filter(function (l) { return !isDraft(l) && (!l.lease_start || l.lease_start <= t); })[0]
      || byStart.filter(function (l) { return !isDraft(l); })[0]
      || byStart[0];
  }

  // Schedule rows for one lease: owed rows from today's call, plus later rows from the look-ahead
  function rowsFor(sched, leaseId) {
    if (!sched || !leaseId) return [];
    var seen = {}, out = [];
    (sched.today || []).concat(sched.ahead || []).forEach(function (r) {
      if (r.lease_id !== leaseId || seen[r.due_date]) return;
      seen[r.due_date] = true; out.push(r);
    });
    return out.sort(function (a, b) { return a.due_date < b.due_date ? -1 : 1; });
  }

  // The lease's state as the rent schedule sees it: active / holdover / month_to_month / ended
  function leaseState(sched, lease) {
    if (!lease) return null;
    var r = (sched && sched.today || []).filter(function (x) { return x.lease_id === lease.id; })[0];
    if (r && r.lease_state) return r.lease_state;
    var s = String(lease.status || '').toLowerCase();
    if (s.indexOf('term') >= 0 || lease.terminated_date) return 'ended';
    if (s === 'draft') return 'draft';
    if (lease.lease_start && lease.lease_start > today()) return 'upcoming';
    if (lease.lease_end && lease.lease_end < today()) return 'holdover';
    return 'active';
  }
  var STATE_LABELS = {
    active: '✓ Active', holdover: 'Holdover (lease ended, rent continues)', month_to_month: 'Month-to-month',
    ended: 'Ended', draft: 'Draft (not signed yet)', upcoming: 'Starts soon'
  };

  // Rent past its grace period, using the schedule's own grace days (the database's rule)
  function pastDue(row) {
    if (!row || Number(row.balance || 0) <= 0) return false;
    var d = parseDay(row.due_date); if (!d) return false;
    d.setDate(d.getDate() + Number(row.grace_days || 0));
    return ymd(d) < today();
  }

  // URLSearchParams values are already decoded; decoding again throws on a literal '%'
  function safeDecode(v) { try { return decodeURIComponent(v); } catch (e) { return v; } }

  window.rgTenant = {
    ymd: ymd, parseDay: parseDay, fmtDate: fmtDate, today: today, daysUntil: daysUntil,
    mine: mine, schedule: schedule, forUrl: forUrl, pickLease: pickLease, rowsFor: rowsFor,
    leaseState: leaseState, stateLabel: function (s) { return STATE_LABELS[s] || s || '—'; },
    pastDue: pastDue, safeDecode: safeDecode
  };
})();
