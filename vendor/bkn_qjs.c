// bkn_qjs.c — the QuickJS bridge.
//
// One symbol crosses in each direction. JS reaches the host through a single
// native function `__host(op, argsJSON)`, which calls exactly one MFL
// function, `hostCall`. Every capability the sandbox exposes is dispatched in
// MFL, where it is typechecked and readable, rather than in C. That keeps
// this file small and fixed: adding a host capability never touches it.
//
// The MFL symbol name (`mfl_hostCall_0`) is an implementation detail of the
// machin compiler's codegen, so build.sh greps the generated C for it and
// refuses to build if it moves.

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>
#include "quickjs.h"

extern char *mfl_hostCall_0(char *op, char *args);

typedef struct {
    int64_t deadline_ms;
} BknRt;

static int64_t now_ms_(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int bkn_interrupt(JSRuntime *rt, void *opaque) {
    BknRt *b = (BknRt *)opaque;
    if (b->deadline_ms > 0 && now_ms_() > b->deadline_ms) return 1;
    return 0;
}

static JSValue js_host(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    const char *op = argc > 0 ? JS_ToCString(ctx, argv[0]) : NULL;
    const char *args = argc > 1 ? JS_ToCString(ctx, argv[1]) : NULL;
    if (!op) return JS_ThrowTypeError(ctx, "__host: missing op");
    char *res = mfl_hostCall_0((char *)op, (char *)(args ? args : "[]"));
    JSValue out = JS_NewString(ctx, res ? res : "{\"ok\":false,\"error\":\"host returned nothing\"}");
    JS_FreeCString(ctx, op);
    if (args) JS_FreeCString(ctx, args);
    return out;
}

// The prelude is the sandbox's whole visible surface. Anything not named here
// simply does not exist inside a script: there is no module loader, no
// filesystem, no process, and no network except through http.
// The prelude is the sandbox's whole visible surface. Anything not named here
// simply does not exist inside a script: there is no module loader, no
// filesystem, no process, and no network except through http. The names match
// the published guide exactly — a script written against the documentation
// has to run here unchanged, or the port is not a port.
static const char *BKN_PRELUDE =
"globalThis.__logs = [];\n"
"function __call(op, args) {\n"
"  var r = JSON.parse(__host(op, JSON.stringify(args || [])));\n"
"  if (!r.ok) { throw new Error(r.error || 'host error'); }\n"
"  return r.value;\n"
"}\n"
"function __fmt(a) { return Array.prototype.map.call(a, function (v) {\n"
"  return typeof v === 'string' ? v : JSON.stringify(v); }).join(' '); }\n"
"var console = { log: function () { __logs.push(__fmt(arguments)); },\n"
"                error: function () { __logs.push(__fmt(arguments)); },\n"
"                warn: function () { __logs.push(__fmt(arguments)); } };\n"
"var log = { info: function (m, d) { __call('log', ['info', m, d || null]); },\n"
"            warn: function (m, d) { __call('log', ['warn', m, d || null]); },\n"
"            error: function (m, d) { __call('log', ['error', m, d || null]); } };\n"
"var crypto = {\n"
"  hmac: function (k, m) { return __call('crypto.hmac', [k, m]); },\n"
"  sha256: function (m) { return __call('crypto.sha256', [m]); },\n"
"  equal: function (a, b) { return __call('crypto.equal', [a, b]); },\n"
"  randomHex: function (n) { return __call('crypto.randomHex', [n || 16]); } };\n"
"var id = { new: function () { return __call('id.new', []); } };\n"
"function now(unit) { return __call('now', [unit || 'iso']); }\n"
"var store = {\n"
"  get: function (ref, i) { return __call('store.get', [ref, i]); },\n"
"  put: function (ref, doc, i) { return __call('store.put', [ref, doc, i || '']); },\n"
"  putIfAbsent: function (ref, doc, i) { return __call('store.putIfAbsent', [ref, doc, i || '']); },\n"
"  patch: function (ref, i, doc) { return __call('store.patch', [ref, i, doc]); },\n"
"  delete: function (ref, i) { return __call('store.delete', [ref, i]); },\n"
"  list: function (ref, o) { return __call('store.list', [ref, o || {}]); },\n"
"  find: function (ref, o) { return __call('store.find', [ref, o || {}]); },\n"
"  count: function (ref, o) { return __call('store.count', [ref, o || {}]); } };\n"
"var kv = {\n"
"  get: function (k) { return __call('kv.get', [k]); },\n"
"  set: function (k, v, o) { return __call('kv.set', [k, v, o || {}]); },\n"
"  delete: function (k) { return __call('kv.delete', [k]); },\n"
"  list: function (p) { return __call('kv.list', [p || '']); } };\n"
"var events = {\n"
"  emit: function (s, t, o) { return __call('events.emit', [s, t, o || {}]); },\n"
"  list: function (s, o) { return __call('events.list', [s, o || {}]); },\n"
"  prune: function (s, older) { return __call('events.prune', [s, older]); } };\n"
"var files = {\n"
"  put: function (ns, n, b, c) { return __call('files.put', [ns, n, b, c || '']); },\n"
"  get: function (ns, n) { return __call('files.get', [ns, n]); },\n"
"  list: function (ns) { return __call('files.list', [ns]); },\n"
"  delete: function (ns, n) { return __call('files.delete', [ns, n]); } };\n"
"var http = { fetch: function (u, o) { return __call('http.fetch', [u, o || {}]); } };\n"
"var lock = {\n"
"  acquire: function (k, ttl) { return __call('lock.acquire', [k, ttl || 300]); },\n"
"  release: function (k, owner) { return __call('lock.release', [k, owner]); } };\n"
"var auth = {\n"
"  me: function (t) { return __call('auth.me', [t]); },\n"
"  can: function (u, o, r) { return __call('auth.can', [u, o, r]); } };\n"
"globalThis.bkn = { auth: auth, crypto: crypto, events: events, files: files,\n"
"  http: http, id: id, kv: kv, lock: lock, log: log, now: now, store: store };\n";

static char *dup_json_err(JSContext *ctx, JSValue exc) {
    const char *msg = JS_ToCString(ctx, exc);
    size_t n = msg ? strlen(msg) : 0;
    char *buf = malloc(n * 6 + 64);
    char *w = buf;
    w += sprintf(w, "{\"ok\":false,\"error\":\"");
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)msg[i];
        if (c == '"' || c == '\\') { *w++ = '\\'; *w++ = (char)c; }
        else if (c < 0x20) w += sprintf(w, "\\u%04x", c);
        else *w++ = (char)c;
    }
    w += sprintf(w, "\"}");
    *w = 0;
    if (msg) JS_FreeCString(ctx, msg);
    return buf;
}

// Settle a returned promise by draining the job queue. A script that awaits
// anything returns a promise; without this it would report `{}` as its value,
// which is the kind of answer that looks like a bug in the script.
static JSValue settle(JSContext *ctx, JSValue v) {
    if (JS_IsException(v)) return v;
    for (int guard = 0; guard < 100000; guard++) {
        int state = JS_PromiseState(ctx, v);
        if (state < 0) return v;  // not a promise
        if (state == JS_PROMISE_FULFILLED) {
            JSValue r = JS_PromiseResult(ctx, v);
            JS_FreeValue(ctx, v);
            return r;
        }
        if (state == JS_PROMISE_REJECTED) {
            JSValue r = JS_PromiseResult(ctx, v);
            JS_FreeValue(ctx, v);
            return JS_Throw(ctx, r);
        }
        JSContext *c2 = NULL;
        int n = JS_ExecutePendingJob(JS_GetRuntime(ctx), &c2);
        if (n <= 0) break;
    }
    return v;
}

// bkn_js_eval runs `source` with `input` as the handler's argument and
// returns a malloc'd JSON document the caller must free with bkn_js_free.
char *bkn_js_eval(const char *source, const char *input, int timeout_ms, int mem_bytes) {
    JSRuntime *rt = JS_NewRuntime();
    if (!rt) return strdup("{\"ok\":false,\"error\":\"cannot create a JS runtime\"}");
    BknRt b;
    b.deadline_ms = timeout_ms > 0 ? now_ms_() + timeout_ms : 0;
    JS_SetMemoryLimit(rt, mem_bytes > 0 ? (size_t)mem_bytes : (size_t)64 * 1024 * 1024);
    JS_SetMaxStackSize(rt, 1024 * 1024);
    JS_SetInterruptHandler(rt, bkn_interrupt, &b);
    JSContext *ctx = JS_NewContext(rt);
    if (!ctx) { JS_FreeRuntime(rt); return strdup("{\"ok\":false,\"error\":\"cannot create a JS context\"}"); }

    JSValue global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "__host", JS_NewCFunction(ctx, js_host, "__host", 2));
    JS_FreeValue(ctx, global);

    char *out = NULL;
    JSValue r = JS_Eval(ctx, BKN_PRELUDE, strlen(BKN_PRELUDE), "<prelude>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(r)) { JSValue e = JS_GetException(ctx); out = dup_json_err(ctx, e); JS_FreeValue(ctx, e); }
    JS_FreeValue(ctx, r);

    if (!out) {
        r = JS_Eval(ctx, source, strlen(source), "<script>", JS_EVAL_TYPE_GLOBAL);
        if (JS_IsException(r)) { JSValue e = JS_GetException(ctx); out = dup_json_err(ctx, e); JS_FreeValue(ctx, e); }
        JS_FreeValue(ctx, r);
    }

    if (!out) {
        JSValue g = JS_GetGlobalObject(ctx);
        JSValue h = JS_GetPropertyStr(ctx, g, "main");
        if (!JS_IsFunction(ctx, h)) {
            out = strdup("{\"ok\":false,\"error\":\"the script defines no handler(input) function\"}");
        } else {
            JSValue arg = JS_ParseJSON(ctx, input && *input ? input : "{}", strlen(input && *input ? input : "{}"), "<input>");
            if (JS_IsException(arg)) { JS_FreeValue(ctx, arg); arg = JS_NewObject(ctx); }
            JSValue v = settle(ctx, JS_Call(ctx, h, JS_UNDEFINED, 1, (JSValueConst *)&arg));
            JS_FreeValue(ctx, arg);
            if (JS_IsException(v)) {
                JSValue e = JS_GetException(ctx);
                out = dup_json_err(ctx, e);
                JS_FreeValue(ctx, e);
            } else {
                JSValue logs = JS_GetPropertyStr(ctx, g, "__logs");
                JSValue payload = JS_NewObject(ctx);
                JS_SetPropertyStr(ctx, payload, "ok", JS_TRUE);
                JS_SetPropertyStr(ctx, payload, "value", JS_IsUndefined(v) ? JS_NULL : JS_DupValue(ctx, v));
                JS_SetPropertyStr(ctx, payload, "logs", logs);
                JSValue js = JS_JSONStringify(ctx, payload, JS_UNDEFINED, JS_UNDEFINED);
                const char *s = JS_ToCString(ctx, js);
                out = strdup(s ? s : "{\"ok\":true,\"value\":null,\"logs\":[]}");
                if (s) JS_FreeCString(ctx, s);
                JS_FreeValue(ctx, js);
                JS_FreeValue(ctx, payload);
            }
            JS_FreeValue(ctx, v);
        }
        JS_FreeValue(ctx, h);
        JS_FreeValue(ctx, g);
    }

    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    return out ? out : strdup("{\"ok\":false,\"error\":\"no result\"}");
}

void bkn_js_free(char *p) { free(p); }
