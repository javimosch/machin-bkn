// A headless CMS.
//
// Models are documents: a content type is a record describing its fields, so
// adding one is a store put and this script never changes. Everything the
// suite exercises — defaults, minLength, enum, regex, uniqueness, references
// — is declared by the model, not coded here.
//
// Access is by API token rather than a user session, because the callers are
// a build step and a running site, not people. A token carries per-model
// scopes so a published site can hold a read-only credential that cannot be
// turned into a write one.

function main(d) {
  const q = d.query || {};
  const modelName = String(q.model || '');

  const token = d.headers['x-api-token'] || '';
  const grant = token ? bkn.store.get('cms/tokens', String(token)) : null;
  if (!grant) return { status: 401, body: { ok: false, error: 'invalid or missing X-Api-Token' } };

  const model = modelName ? bkn.store.get('cms/models', modelName) : null;
  if (!model) return { status: 404, body: { ok: false, error: 'no such model' } };

  const scope = (grant.scopes || {})[modelName] || '';
  const writing = d.method !== 'GET';
  if (!scope) return { status: 403, body: { ok: false, error: 'token cannot read ' + modelName } };
  if (writing && scope.indexOf('w') < 0) {
    return { status: 403, body: { ok: false, error: 'token cannot write ' + modelName } };
  }

  const ref = model.collection;
  if (d.method === 'GET')    return list(ref, model, q);
  if (d.method === 'POST')   return create(ref, model, d.body);
  if (d.method === 'PATCH' || d.method === 'PUT') return patch(ref, model, q.id, d.body);
  if (d.method === 'DELETE') return remove(ref, q.id);
  return { status: 405, body: { ok: false, error: 'method not allowed' } };
}

// --- reading --------------------------------------------------------------

function list(ref, model, q) {
  const reserved = { model: 1, populate: 1, order_by: 1, order: 1, limit: 1, offset: 1, id: 1 };
  const where = {};
  for (const k in q) if (!reserved[k]) where[k] = String(q[k]);

  const opts = {
    where: where,
    limit: Math.min(Number(q.limit || 50), 500),
    offset: Number(q.offset || 0)
  };
  if (q.order_by) { opts.order_by = String(q.order_by); opts.order = q.order === 'asc' ? 'asc' : 'desc'; }

  let items = q.id ? oneAsList(ref, String(q.id)) : bkn.store.list(ref, opts);

  // total ignores limit and offset on purpose: a pager needs to know how many
  // there are, not how many it was handed.
  const total = q.id ? items.length : bkn.store.count(ref, { where: where });

  const populate = String(q.populate || '').split(',').filter(Boolean);
  if (populate.length) items = items.map(function (it) { return resolve(model, it, populate); });

  return { status: 200, headers: { 'Cache-Control': 'no-store' }, body: { ok: true, items: items, total: total } };
}

function oneAsList(ref, id) {
  const doc = bkn.store.get(ref, id);
  return doc ? [doc] : [];
}

// A reference is stored as an id and resolved on request. Storing the whole
// author inside every article would make renaming her a migration.
function resolve(model, item, populate) {
  for (let i = 0; i < populate.length; i++) {
    const f = fieldOf(model, populate[i]);
    if (!f || f.type !== 'ref' || !item[f.name]) continue;
    const target = bkn.store.get('cms/models', f.model);
    if (!target) continue;
    const doc = bkn.store.get(target.collection, String(item[f.name]));
    if (doc) item[f.name] = doc;
  }
  return item;
}

// --- writing --------------------------------------------------------------

function create(ref, model, body) {
  const input = parse(body);
  if (!input) return { status: 400, body: { ok: false, error: 'body is not JSON' } };

  const doc = {};
  for (let i = 0; i < model.fields.length; i++) {
    const f = model.fields[i];
    let v = input[f.name];
    if (v === undefined || v === null || v === '') {
      if (f.default !== undefined) v = f.default;
      else if (f.required) return invalid(f.name, f.name + ' is required');
      else continue;
    }
    const bad = check(f, v);
    if (bad) return bad;
    const dup = uniqueClash(ref, f, v, '');
    if (dup) return dup;
    doc[f.name] = coerce(f, v);
  }
  doc.created_at = bkn.now();
  doc.updated_at = doc.created_at;
  const rec = bkn.store.put(ref, doc);
  return { status: 201, body: { ok: true, item: rec } };
}

// PATCH touches only the fields it names. Validating the whole model here
// would reject a partial update for missing a required field it was never
// trying to change.
function patch(ref, model, id, body) {
  if (!id) return { status: 400, body: { ok: false, error: 'id is required' } };
  const input = parse(body);
  if (!input) return { status: 400, body: { ok: false, error: 'body is not JSON' } };
  if (!bkn.store.get(ref, String(id))) return { status: 404, body: { ok: false, error: 'not found' } };

  const patchDoc = {};
  for (const k in input) {
    const f = fieldOf(model, k);
    if (!f) continue;
    const v = input[k];
    const bad = check(f, v);
    if (bad) return bad;
    const dup = uniqueClash(ref, f, v, String(id));
    if (dup) return dup;
    patchDoc[k] = coerce(f, v);
  }
  patchDoc.updated_at = bkn.now();
  const rec = bkn.store.patch(ref, String(id), patchDoc);
  return { status: 200, body: { ok: true, item: rec } };
}

function remove(ref, id) {
  if (!id) return { status: 400, body: { ok: false, error: 'id is required' } };
  const gone = bkn.store.delete(ref, String(id));
  if (!gone) return { status: 404, body: { ok: false, error: 'not found' } };
  return { status: 200, body: { ok: true, deleted: true, id: String(id) } };
}

// --- validation -----------------------------------------------------------

function check(f, v) {
  const s = String(v);
  if (f.type === 'number') {
    if (isNaN(Number(v))) return invalid(f.name, f.name + ' must be a number');
    return null;
  }
  if (f.type === 'enum' && (f.values || []).indexOf(s) < 0) {
    return invalid(f.name, s + ' is not one of ' + (f.values || []).join(', '));
  }
  if (f.minLength && s.length < f.minLength) {
    return invalid(f.name, f.name + ' is shorter than ' + f.minLength);
  }
  if (f.maxLength && s.length > f.maxLength) {
    return invalid(f.name, f.name + ' is longer than ' + f.maxLength);
  }
  if (f.regex && !new RegExp(f.regex).test(s)) {
    return invalid(f.name, f.name + ' does not match ' + f.regex);
  }
  return null;
}

// Uniqueness is checked against the store, so deleting a record frees its
// value again — the constraint is about what exists now, not what ever did.
function uniqueClash(ref, f, v, exceptID) {
  if (!f.unique) return null;
  const where = {};
  where[f.name] = String(v);
  const hit = bkn.store.find(ref, { where: where });
  if (hit && hit.id !== exceptID) {
    return { status: 409, body: { ok: false, error: 'must be unique', field: f.name, value: String(v) } };
  }
  return null;
}

function invalid(field, message) {
  return { status: 422, body: { ok: false, error: message, field: field } };
}

function coerce(f, v) {
  if (f.type === 'number') return Number(v);
  if (f.type === 'boolean') return !!v;
  return typeof v === 'object' ? v : String(v);
}

function fieldOf(model, name) {
  for (let i = 0; i < model.fields.length; i++) if (model.fields[i].name === name) return model.fields[i];
  return null;
}

function parse(b) {
  try { return JSON.parse(b); } catch (e) { return null; }
}
