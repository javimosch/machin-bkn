// Feature flags.
//
// A flag is either public or it is not. An anonymous caller is told about the
// public ones only — the existence of an internal flag is itself information
// about what is being built, and a browser is the last place to leak it.

function main(d) {
  const q = d.query || {};
  const anon = String(q.anon || '');
  const defs = bkn.store.list('flags/definitions', { limit: 500 });

  const flags = {};
  for (let i = 0; i < defs.length; i++) {
    const f = defs[i];
    if (!f.public) continue;
    flags[f.id] = decide(f, anon);
  }
  return {
    status: 200,
    headers: { 'Cache-Control': 'private, max-age=30' },
    body: { ok: true, anon: anon, flags: flags }
  };
}

function decide(f, anon) {
  if (!f.enabled) return false;
  if (f.rollout === undefined || f.rollout === null) return true;
  if (!anon) return false;
  // Bucket by a hash of the identity, never at random: the same visitor has
  // to get the same answer on every request, or a half-rolled-out feature
  // flickers on and off as they browse.
  return bucket(anon + ':' + f.id) < Number(f.rollout);
}

function bucket(s) {
  return parseInt(bkn.crypto.sha256(s).slice(0, 8), 16) % 100;
}
