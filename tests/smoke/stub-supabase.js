/* Stand-in for supabase-js used by the smoke tests (tests/smoke/run.js serves it in place of the
   CDN script). It never talks to a network: auth returns the fixture user, queries read
   window.__RG_FIXTURE, writes are recorded in window.__rgWrites and succeed, rpc() returns
   fixture.rpc[name], functions.invoke() returns fixture.functions[name] and records the call in
   window.__rgInvokes. order() and range() are honoured; fixture.maxRows imitates the API row cap
   and fixture.errors[table] makes a table fail. Filters are applied loosely (eq / neq / in / is / ilike / gte / lte); anything
   else is accepted and ignored, because the goal is "the page renders without errors", not
   query correctness. */
(function () {
  var W = window;
  var F = W.__RG_FIXTURE || {};
  var user = F.user || null;
  W.__rgWrites = [];

  function clone(v) { return v == null ? v : JSON.parse(JSON.stringify(v)); }
  function like(val, pat) {
    var re = new RegExp('^' + String(pat).replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/%/g, '.*').replace(/_/g, '.') + '$', 'i');
    return re.test(String(val == null ? '' : val));
  }

  function query(table) {
    var st = { op: 'select', filters: [], one: false, head: false, count: null, limit: null, range: null, orders: [], payload: null };
    var b = {};
    function chain(name, fn) { b[name] = function () { if (fn) fn.apply(null, arguments); return b; }; }
    chain('select', function (_cols, opts) { if (opts && opts.head) st.head = true; if (opts && opts.count) st.count = opts.count; });
    chain('eq', function (k, v) { st.filters.push(function (r) { return !(k in r) || String(r[k]) === String(v); }); });
    chain('neq', function (k, v) { st.filters.push(function (r) { return !(k in r) || String(r[k]) !== String(v); }); });
    chain('in', function (k, vs) { st.filters.push(function (r) { return !(k in r) || (vs || []).map(String).indexOf(String(r[k])) >= 0; }); });
    chain('is', function (k, v) { st.filters.push(function (r) { return !(k in r) || (v === null ? r[k] == null : r[k] === v); }); });
    chain('ilike', function (k, p) { st.filters.push(function (r) { return !(k in r) || like(r[k], String(p).replace(/\\(.)/g, '$1')); }); });
    chain('like', function (k, p) { st.filters.push(function (r) { return !(k in r) || like(r[k], p); }); });
    chain('gte', function (k, v) { st.filters.push(function (r) { return !(k in r) || r[k] == null || r[k] >= v; }); });
    chain('lte', function (k, v) { st.filters.push(function (r) { return !(k in r) || r[k] == null || r[k] <= v; }); });
    ['gt', 'lt', 'not', 'or', 'match', 'filter', 'contains', 'containedBy', 'overlaps', 'textSearch',
     'abortSignal', 'returns', 'csv', 'throwOnError'].forEach(function (n) { chain(n); });
    chain('order', function (k, o) { st.orders.push([k, !(o && o.ascending === false)]); });
    chain('range', function (from, to) { st.range = [from, to]; });
    chain('limit', function (n) { st.limit = n; });
    chain('single', function () { st.one = true; });
    chain('maybeSingle', function () { st.one = true; });
    ['insert', 'update', 'upsert', 'delete'].forEach(function (op) {
      chain(op, function (payload) { st.op = op; st.payload = payload; });
    });
    b.then = function (resolve, reject) {
      var out;
      if (st.op !== 'select') {
        W.__rgWrites.push({ table: table, op: st.op, payload: clone(st.payload) });
        var rows = Array.isArray(st.payload) ? st.payload : [st.payload || {}];
        rows = rows.map(function (r, i) { return Object.assign({ id: 'stub-' + table + '-' + i }, r); });
        out = { data: st.one ? rows[0] : rows, error: null, count: rows.length, status: 201 };
      } else {
        if ((F.errors || {})[table]) { out = { data: null, error: { message: F.errors[table] }, count: null, status: 400 }; return Promise.resolve(out).then(resolve, reject); }
        var data = clone(F[table] || []).filter(function (r) { return st.filters.every(function (f) { return f(r); }); });
        var total = data.length;
        if (st.orders.length) data.sort(function (a, b) {
          for (var i = 0; i < st.orders.length; i++) {
            var k = st.orders[i][0], asc = st.orders[i][1];
            if (a[k] < b[k]) return asc ? -1 : 1;
            if (a[k] > b[k]) return asc ? 1 : -1;
          }
          return 0;
        });
        if (st.range) data = data.slice(st.range[0], st.range[1] + 1);
        if (st.limit != null) data = data.slice(0, st.limit);
        // fixture.maxRows imitates the API's per-request row cap
        if (F.maxRows && !st.head) data = data.slice(0, F.maxRows);
        out = { data: st.head ? null : (st.one ? (data[0] || null) : data), error: null, count: total, status: 200 };
      }
      return Promise.resolve(out).then(resolve, reject);
    };
    b.catch = function (fn) { return b.then(null, fn); };
    return b;
  }

  function session() { return user ? { user: user, access_token: 'stub-token', expires_at: 4102444800 } : null; }
  var listeners = [];
  var ok = function (data) { return Promise.resolve({ data: data || {}, error: null }); };

  W.supabase = {
    createClient: function () {
      return {
        auth: {
          getUser: function () { return ok({ user: user }); },
          getSession: function () { return ok({ session: session() }); },
          onAuthStateChange: function (cb) {
            listeners.push(cb);
            setTimeout(function () { try { cb(user ? 'INITIAL_SESSION' : 'SIGNED_OUT', session()); } catch (e) { setTimeout(function () { throw e; }); } }, 0);
            return { data: { subscription: { unsubscribe: function () {} } } };
          },
          signInWithPassword: function () { return ok({ user: user, session: session() }); },
          signInWithOtp: function () { return ok({}); },
          signUp: function () { return ok({ user: user, session: null }); },
          signOut: function () { return Promise.resolve({ error: null }); },
          updateUser: function () { return ok({ user: user }); },
          resetPasswordForEmail: function () { return ok({}); },
          refreshSession: function () { return ok({ session: session() }); },
          setSession: function () { return ok({ session: session() }); },
          exchangeCodeForSession: function () { return ok({ session: session() }); }
        },
        from: query,
        rpc: function (name, args) {
          var r = (F.rpc || {})[name];
          return ok(typeof r === 'function' ? r(args) : clone(r === undefined ? [] : r));
        },
        storage: {
          from: function () {
            return {
              upload: function (p) { return ok({ path: p }); },
              remove: function () { return ok([]); },
              list: function () { return ok([]); },
              download: function () { return ok(new Blob([''])); },
              createSignedUrl: function () { return ok({ signedUrl: 'about:blank' }); },
              createSignedUrls: function (ps) { return ok((ps || []).map(function (p) { return { path: p, signedUrl: 'about:blank' }; })); },
              getPublicUrl: function (p) { return { data: { publicUrl: 'about:blank#' + p } }; }
            };
          }
        },
        functions: {
          invoke: function (name, opts) {
            (W.__rgInvokes = W.__rgInvokes || []).push({ name: name, body: clone(opts && opts.body) });
            var r = (F.functions || {})[name];
            return ok(typeof r === 'function' ? r(opts && opts.body) : clone(r === undefined ? {} : r));
          }
        },
        channel: function () { var c = { on: function () { return c; }, subscribe: function () { return c; }, unsubscribe: function () {} }; return c; },
        removeChannel: function () { return Promise.resolve('ok'); },
        removeAllChannels: function () { return Promise.resolve([]); }
      };
    }
  };
})();
