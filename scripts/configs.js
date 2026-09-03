// JSON configuration documents.
//
// A config is addressed by slug or by any of its aliases, so a page can keep
// asking for `dogprice` while the document it resolves to is renamed or
// replaced. The alias is a record, not a field, which is what makes the
// lookup one indexed read instead of a scan.

function main(d) {
  const q = d.query || {};
  const slug = q.slug ? String(q.slug) : aliasTo(String(q.alias || ''));
  if (!slug) return { status: 404, body: { ok: false, error: 'no such config' } };

  const doc = bkn.store.get('configs/documents', slug);
  if (!doc) return { status: 404, body: { ok: false, error: 'no such config' } };

  const ttl = doc.ttl === undefined ? 300 : Number(doc.ttl);
  const headers = { 'Cache-Control': 'public, max-age=' + ttl };

  // raw=1 answers with the document itself, for a client that wants to fetch
  // its configuration straight into a variable rather than unwrap an envelope.
  if (q.raw) return { status: 200, headers: headers, body: doc.data };

  return {
    status: 200,
    headers: headers,
    body: { ok: true, slug: doc.slug || slug, ttl: ttl, data: doc.data }
  };
}

function aliasTo(alias) {
  if (!alias) return '';
  const rec = bkn.store.get('configs/aliases', alias);
  return rec ? rec.slug : '';
}
