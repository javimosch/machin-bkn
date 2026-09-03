// The runtime suite's probe: proves the sandbox computes a real HMAC and
// exposes exactly the documented surface.
function main(d) {
  return {
    hmac12: bkn.crypto.hmac('k', 'm').slice(0, 12),
    has: Object.keys(bkn).sort().join(','),
    at: bkn.now()
  };
}
