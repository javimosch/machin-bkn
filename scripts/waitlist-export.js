// CSV export of one form's submissions.
//
// The password is checked against a kv entry, accepted either as ?password=
// or as a bearer token, because this endpoint is reached both by a browser
// download link and by a script. It is a shared secret guarding a read, not
// an identity — a real operator export goes through auth.

function main(d) {
  const expected = bkn.kv.get('forms.export_password');
  const given = d.query.password || bearer(d.headers);
  if (!expected || !given || !bkn.crypto.equal(String(expected), String(given))) {
    return { status: 401, body: { ok: false, error: 'invalid or missing password' } };
  }

  const name = d.query.name || '';
  const def = bkn.store.get('forms/definitions', name);
  if (!def) return { status: 404, body: { ok: false, error: 'no such form' } };

  const columns = def.fields.map(function (f) { return f.name; }).concat(['submitted_at']);
  const rows = bkn.store.list('forms/submissions', {
    where: { form: name },
    order_by: 'submitted_at',
    order: 'asc',
    limit: 5000
  });

  const lines = [columns.map(csvCell).join(',')];
  for (let i = 0; i < rows.length; i++) {
    lines.push(columns.map(function (c) { return csvCell(rows[i][c]); }).join(','));
  }

  // A CSV, not a JSON envelope containing a CSV: the content type says what
  // it is and the body is written verbatim, so the browser saves a file the
  // spreadsheet opens.
  return {
    status: 200,
    content_type: 'text/csv; charset=utf-8',
    body: lines.join('\r\n') + '\r\n'
  };
}

// RFC 4180: quote when the value contains a comma, a quote or a newline, and
// escape an embedded quote by doubling it.
function csvCell(v) {
  const s = v === undefined || v === null ? '' : String(v);
  if (/[",\r\n]/.test(s)) return '"' + s.replace(/"/g, '""') + '"';
  return s;
}

function bearer(h) {
  const a = h['authorization'] || '';
  return a.slice(0, 7) === 'Bearer ' ? a.slice(7) : '';
}
