// The script-execution scenario, deliberately confined to the intersection of
// the two sandbox surfaces: a store read, an HMAC, a JSON response.
//
// Not used: bkn.log and bkn.id. Each is a function in one implementation and an
// object in the other, so touching either would benchmark a TypeError rather
// than a script.
//
// Keys are sorted before hashing because the two implementations disagree on
// object key order (Go hands back sorted keys, a Go-map marshalling artifact;
// MFL preserves insertion order, which is what the JS spec requires). Sorting
// makes the response byte-identical on both, so the harness can assert the two
// servers really did the same work before comparing how fast they did it.
function main(d) {
  const q = d.query || {};
  const locale = q.locale ? String(q.locale) : 'en';
  const bundle = bkn.store.get('i18n/bundles', locale);
  if (!bundle) return { status: 404, body: { ok: false } };
  const keys = Object.keys(bundle.entries || {}).sort();
  const tag = bkn.crypto.hmac('bench', keys.join(','));
  return { status: 200, body: { ok: true, locale: locale, n: keys.length, tag: String(tag).slice(0, 12) } };
}
