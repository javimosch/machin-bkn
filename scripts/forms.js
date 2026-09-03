// Form intake.
//
// The definition is a document, not code: a new form is a store record, and
// this script never changes. Validation is therefore driven entirely by what
// the definition declares — required, enum values, max length, the honeypot
// field name, and whether the form dedupes.

function main(d) {
  if (d.method === 'GET') {
    const def = bkn.store.get('forms/definitions', d.query.form || '');
    if (!def) return { status: 404, body: { ok: false, error: 'no such form' } };
    return { status: 200, body: def };
  }

  const req = parseBody(d.body);
  if (!req) return { status: 400, body: { ok: false, error: 'body is not JSON' } };

  const def = bkn.store.get('forms/definitions', req.form || '');
  if (!def) return { status: 404, body: { ok: false, error: 'no such form' } };

  const submitted = req.fields || {};

  // The honeypot is a field a human never sees and a bot always fills. The
  // answer has to be indistinguishable from success, or the bot learns the
  // field name and stops filling it — so: same shape, no id, nothing stored.
  if (def.honeypot && submitted[def.honeypot]) {
    bkn.events.emit('forms', 'form.honeypot', { subject: req.form, level: 'warn' });
    return { status: 200, body: { ok: true } };
  }

  const clean = {};
  for (let i = 0; i < def.fields.length; i++) {
    const f = def.fields[i];
    let v = submitted[f.name];
    v = v === undefined || v === null ? '' : String(v);
    if (f.type === 'email') v = v.trim().toLowerCase();
    else v = v.trim();

    if (f.required && v === '') {
      return { status: 422, body: { ok: false, error: f.name + ' is required', field: f.name } };
    }
    if (v !== '') {
      if (f.type === 'email' && !/^[^@\s]+@[^@\s.]+\.[^@\s]+$/.test(v)) {
        return { status: 422, body: { ok: false, error: 'not an email address', field: f.name } };
      }
      if (f.type === 'enum' && f.values.indexOf(v) < 0) {
        return { status: 422, body: { ok: false, error: v + ' is not one of ' + f.values.join(', '), field: f.name } };
      }
      if (f.max && v.length > f.max) {
        return { status: 422, body: { ok: false, error: f.name + ' is longer than ' + f.max, field: f.name } };
      }
    }
    clean[f.name] = v;
  }

  // Dedupe after normalizing, never before: "  Ada@Dog.IO " and "ada@dog.io"
  // are the same person signing up twice, and only the normalized form knows
  // that.
  if (def.dedupe_on) {
    const where = { form: req.form };
    where[def.dedupe_on] = clean[def.dedupe_on];
    const existing = bkn.store.find('forms/submissions', { where: where });
    if (existing) return { status: 200, body: { ok: true, duplicate: true, id: existing.id } };
  }

  clean.form = req.form;
  clean.submitted_at = bkn.now();
  const rec = bkn.store.put('forms/submissions', clean);
  bkn.events.emit('forms', 'form.submitted', { subject: req.form, data: { id: rec.id } });
  return { status: 200, body: { ok: true, id: rec.id } };
}

function parseBody(b) {
  try { return JSON.parse(b); } catch (e) { return null; }
}
