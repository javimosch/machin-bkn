// Stripe webhook handler.
//
// Billing state lives in its own collection keyed by the Stripe customer, not
// on the user record. A user is who someone is; a subscription is what they
// are paying for this month. Merging the two means every plan change rewrites
// an identity row, and every identity read drags billing along with it.

function main(d) {
  const secret = bkn.kv.get('stripe.webhook_secret');
  if (!secret) return { status: 500, body: { error: 'stripe.webhook_secret is not set' } };

  const parts = {};
  (d.headers['stripe-signature'] || '').split(',').forEach(function (p) {
    const eq = p.indexOf('=');
    if (eq > 0) parts[p.slice(0, eq)] = p.slice(eq + 1);
  });

  // Timestamp first: an old delivery with a valid signature is a replay, and
  // checking the signature first would make it look merely wrong.
  const age = Math.abs(Number(bkn.now('unix')) - Number(parts.t || 0));
  if (!parts.t || age > 300) {
    return { status: 400, body: { error: 'timestamp outside the tolerance window' } };
  }

  // The signature covers the exact bytes Stripe sent. d.body is byte-for-byte
  // what arrived; re-serializing the parsed object here would break it.
  const expected = bkn.crypto.hmac(secret, parts.t + '.' + d.body);
  if (!bkn.crypto.equal(expected, parts.v1 || '')) {
    return { status: 400, body: { error: 'signature mismatch' } };
  }

  const evt = JSON.parse(d.body);

  // The ledger is the idempotency key. putIfAbsent answers null when the id
  // was already there, which distinguishes a retry from a first delivery
  // without a get-then-put race that a retry would eventually find.
  const first = bkn.store.putIfAbsent('stripe/events', {
    type: evt.type,
    received_at: bkn.now()
  }, evt.id);
  if (first === null) {
    return { status: 200, body: { ok: true, duplicate: true, type: evt.type } };
  }

  const obj = (evt.data && evt.data.object) || {};
  const customer = obj.customer || obj.id;

  if (evt.type === 'checkout.session.completed') {
    const details = obj.customer_details || {};
    const meta = obj.metadata || {};
    upsertSubject(customer, {
      email: details.email || '',
      plan: meta.plan || 'free',
      status: 'active',
      stripe_customer_id: customer
    });
    bkn.events.emit('billing', 'checkout.completed', {
      subject: customer, data: { plan: meta.plan || 'free' }
    });
    return { status: 200, body: { ok: true, type: evt.type, customer: customer } };
  }

  if (evt.type === 'customer.subscription.updated' ||
      evt.type === 'customer.subscription.deleted') {
    upsertSubject(customer, {
      status: evt.type === 'customer.subscription.deleted' ? 'canceled' : (obj.status || 'active'),
      cancel_at_period_end: !!obj.cancel_at_period_end,
      stripe_customer_id: customer
    });
    bkn.events.emit('billing', 'subscription.' + (obj.status || 'updated'), {
      subject: customer, data: { cancel_at_period_end: !!obj.cancel_at_period_end }
    });
    return { status: 200, body: { ok: true, type: evt.type } };
  }

  // An unhandled type is still an accepted delivery. Answering anything but
  // 200 here would make Stripe retry an event we have already decided about.
  return { status: 200, body: { ok: true, ignored: evt.type } };
}

// A patch that creates the record when it is absent, so the two event kinds
// can arrive in either order — Stripe does not promise a sequence.
function upsertSubject(customer, fields) {
  if (!customer) return;
  const patched = bkn.store.patch('billing/subjects', customer, fields);
  if (patched === null) bkn.store.put('billing/subjects', fields, customer);
}
