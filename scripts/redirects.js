// Page redirects.
//
// Rules are documents, matched exact-first then by longest prefix. Matching
// is done on a normalized path — lowercased, one trailing slash removed —
// because /DOG-OLD/ and /dog-old are the same page to everyone except a
// string comparison.

function main(d) {
  const raw = String((d.query || {}).path || '');
  if (!raw) return { status: 400, body: { ok: false, error: 'path is required' } };

  const qmark = raw.indexOf('?');
  const query = qmark >= 0 ? raw.slice(qmark) : '';
  const path = normalize(qmark >= 0 ? raw.slice(0, qmark) : raw);

  const exact = bkn.store.find('redirects/rules', { where: { match: 'exact', from: path } });
  if (exact) return go(exact, exact.to, query);

  // Longest prefix wins, so /dogdocs/api can be redirected somewhere other
  // than /dogdocs without the order of the rules deciding it.
  const prefixes = bkn.store.list('redirects/rules', { where: { match: 'prefix' }, limit: 500 });
  let best = null;
  for (let i = 0; i < prefixes.length; i++) {
    const r = prefixes[i];
    const from = normalize(r.from);
    if (path === from || path.indexOf(from + '/') === 0) {
      if (!best || from.length > normalize(best.from).length) best = r;
    }
  }
  if (best) {
    const rest = path.slice(normalize(best.from).length);
    return go(best, best.to + rest, query);
  }

  return { status: 404, body: { ok: false, error: 'no rule matches', path: path } };
}

function go(rule, target, query) {
  bkn.events.emit('redirects', 'redirect.hit', { subject: rule.from, data: { to: target } });
  // The query string is the caller's, not the rule's: dropping it loses the
  // campaign tracking that is usually the only reason the old link exists.
  return {
    status: rule.status || 301,
    headers: { Location: target + query, 'Cache-Control': 'public, max-age=3600' },
    body: { ok: true, to: target + query }
  };
}

function normalize(p) {
  let s = String(p).trim().toLowerCase();
  if (s.length > 1 && s.slice(-1) === '/') s = s.slice(0, -1);
  return s;
}
