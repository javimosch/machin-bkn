// Translation bundles.
//
// A locale is a document that may name a fallback, so fr carries only what
// differs from en and inherits the rest. That is the difference between a
// translation file and a fork of one: a new English string appears in every
// locale immediately, untranslated but present, instead of vanishing.

function main(d) {
  const q = d.query || {};
  const locale = q.locale ? String(q.locale) : negotiate(d.headers['accept-language'] || '');
  const bundle = resolve(locale);
  if (!bundle) return { status: 404, body: { ok: false, error: 'no such locale' } };

  if (q.key) {
    const key = String(q.key);
    const raw = bundle.entries[key];
    if (raw === undefined) {
      // A missing key is a content gap, not an error: answer with the key so
      // the page still renders, and queue it so someone can translate it.
      bkn.store.putIfAbsent('i18n/missing', {
        locale: locale, key: key, first_seen: bkn.now()
      }, locale + ':' + key);
      return { status: 200, body: { ok: true, locale: locale, key: key, value: key, missing: true } };
    }
    return { status: 200, body: { ok: true, locale: locale, key: key, value: interpolate(raw, parseVars(q.vars)) } };
  }

  // The bundle's identity is its content, so the ETag is a hash of it. A
  // client that already has this exact set of strings gets a 304.
  const payload = { ok: true, locale: locale, entries: bundle.entries };
  const etag = '"' + bkn.crypto.sha256(JSON.stringify(payload)).slice(0, 16) + '"';
  if ((d.headers['if-none-match'] || '') === etag) {
    return { status: 304, headers: { ETag: etag, 'Cache-Control': 'public, max-age=60' } };
  }
  return {
    status: 200,
    headers: { ETag: etag, 'Cache-Control': 'public, max-age=60' },
    body: payload
  };
}

// Merge the fallback chain from the base up, so a locale overrides what it
// translates and inherits everything it has not reached yet.
function resolve(locale) {
  const chain = [];
  let cur = locale;
  for (let i = 0; i < 8 && cur; i++) {
    const doc = bkn.store.get('i18n/bundles', cur);
    if (!doc) break;
    chain.unshift(doc);
    cur = doc.fallback || '';
  }
  if (!chain.length) return null;
  const entries = {};
  for (let i = 0; i < chain.length; i++) {
    const e = chain[i].entries || {};
    for (const k in e) entries[k] = e[k];
  }
  return { entries: entries };
}

// Accept-Language, by q-weight, restricted to locales we actually have. A
// weight is a preference, not an instruction: the highest one we can serve
// wins, not the highest one asked for.
function negotiate(header) {
  const wanted = header.split(',').map(function (part) {
    const bits = part.trim().split(';');
    const tag = bits[0].trim().toLowerCase();
    let q = 1;
    for (let i = 1; i < bits.length; i++) {
      const kv = bits[i].split('=');
      if (kv[0].trim() === 'q') q = parseFloat(kv[1]) || 0;
    }
    return { tag: tag, q: q };
  }).filter(function (w) { return w.tag && w.q > 0; });
  wanted.sort(function (a, b) { return b.q - a.q; });

  for (let i = 0; i < wanted.length; i++) {
    const tag = wanted[i].tag;
    if (bkn.store.get('i18n/bundles', tag)) return tag;
    const base = tag.split('-')[0];
    if (base !== tag && bkn.store.get('i18n/bundles', base)) return base;
  }
  return 'en';
}

function parseVars(v) {
  if (!v) return {};
  try { return JSON.parse(String(v)); } catch (e) { return {}; }
}

function interpolate(s, vars) {
  return String(s).replace(/\{(\w+)\}/g, function (m, name) {
    return vars[name] === undefined ? m : String(vars[name]);
  });
}
