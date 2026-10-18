// Test del Worker con node:test, senza dipendenze: cd worker && node --test
// Ambiente finto: Cache API, fetch verso Telegram e Plausible, KV, rate limit e un D1 vero su SQLite
// (node:sqlite) con le migration di worker/migrations applicate in ordine.
// CORNETTA_WORKER e CORNETTA_WRANGLER_TOML puntano a un'altra versione dei file, per la prova sul codice vecchio.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { DatabaseSync } from "node:sqlite";

const WORKER_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const MODULE = process.env.CORNETTA_WORKER || join(WORKER_DIR, "src", "index.js");
const TOML = process.env.CORNETTA_WRANGLER_TOML || join(WORKER_DIR, "wrangler.toml");
const worker = (await import(pathToFileURL(MODULE).href)).default;

const PAGINA_FINTA = "<!doctype html><title>Cornetta</title>" + "<p>registra le chiamate</p>".repeat(200);
const BROWSER = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";
const INSTALL = "0f8fad5b-d9cb-469f-a165-70867728950e";

// MARK: - Ambiente finto

function ratelimitConfig() {
  // I blocchi [[ratelimits]] di wrangler.toml: nome → limite per periodo.
  const out = {};
  for (const block of readFileSync(TOML, "utf8").split("[[ratelimits]]").slice(1)) {
    const name = block.match(/name\s*=\s*"([^"]+)"/)?.[1];
    const limit = Number(block.match(/limit\s*=\s*(\d+)/)?.[1]);
    const period = Number(block.match(/period\s*=\s*(\d+)/)?.[1]);
    if (name) out[name] = { limit, period };
  }
  return out;
}

class FakeLimiter {
  constructor(limit) { this.limit_ = limit; this.counts = new Map(); this.keys = []; }
  async limit({ key }) {
    this.keys.push(key);
    const n = (this.counts.get(key) || 0) + 1;
    this.counts.set(key, n);
    return { success: n <= this.limit_ };
  }
}

class FakeKV {
  constructor() { this.data = new Map(); this.puts = []; }
  async get(key) { return this.data.has(key) ? this.data.get(key).value : null; }
  async put(key, value, options = {}) { this.puts.push({ key, value, options }); this.data.set(key, { value, options }); }
}

function fakeD1() {
  const db = new DatabaseSync(":memory:");
  const dir = join(WORKER_DIR, "migrations");
  for (const file of readdirSync(dir).filter((f) => f.endsWith(".sql")).sort()) db.exec(readFileSync(join(dir, file), "utf8"));
  return {
    db,
    prepare(sql) {
      return { bind: (...params) => ({ run: async () => db.prepare(sql).run(...params) }) };
    },
  };
}

function setup() {
  const limits = ratelimitConfig();
  const sent = { telegram: [], plausible: [] };
  const cache = new Map();
  globalThis.caches = {
    default: {
      async match(request) { return cache.has(request.url) ? new Response("1") : undefined; },
      async put(request) { cache.set(request.url, true); },
    },
  };
  globalThis.fetch = async (input, init = {}) => {
    const url = typeof input === "string" ? input : input.url;
    if (url.startsWith("https://api.telegram.org/")) {
      sent.telegram.push(JSON.parse(init.body).text);
      return Response.json({ ok: true, result: { message_id: sent.telegram.length } });
    }
    if (url.includes("/api/event")) {
      sent.plausible.push(JSON.parse(init.body));
      return new Response(null, { status: 202 });
    }
    return new Response("", { status: 404 });
  };
  const limiters = {};
  for (const [name, cfg] of Object.entries(limits)) limiters[name] = new FakeLimiter(cfg.limit);
  const env = {
    TELEGRAM_TOKEN: "token-finto",
    TELEGRAM_CHAT: "1",
    ASSETS: {
      async fetch(request) {
        const url = typeof request === "string" ? request : request.url;
        if (url.endsWith("/downloads/latest.json")) return Response.json({ mac: { version: "0.3.4" }, windows: { version: "0.3.0" } });
        if (url.endsWith("/")) return new Response(PAGINA_FINTA, { headers: { "content-type": "text/html; charset=utf-8" } });
        return new Response("file");
      },
    },
    FEEDBACK: new FakeKV(),
    TELEMETRY: fakeD1(),
    ...limiters,
  };
  return { env, sent, limits, limiters };
}

async function call(env, { path, method = "GET", ip = "203.0.113.7", agent = BROWSER, body, headers = {} }) {
  const init = { method, headers: { "cf-connecting-ip": ip, "user-agent": agent, ...headers } };
  if (body !== undefined) {
    init.body = typeof body === "string" ? body : JSON.stringify(body);
    init.headers["content-type"] = "application/json";
  }
  const request = new Request("https://cornetta.stellakamikaze.org" + path, init);
  Object.defineProperty(request, "cf", { value: { country: "IT" } });
  const pending = [];
  const response = await worker.fetch(request, env, { waitUntil: (p) => pending.push(p) });
  await Promise.all(pending);
  return response;
}

const feedback = (message = "Funziona bene, grazie") => ({ message, name: "Mario", email: "mario@example.com", platform: "windows", app: { version: "0.3.0" } });
const event = (evento = "avvio") => ({ evento, piattaforma: "windows", versione: "0.3.0", os: "Windows 10.0.26100", arch: "x64", installazione: INSTALL });

// MARK: - Configurazione

test("wrangler.toml: niente workers.dev, limiti col binding ratelimits", () => {
  const toml = readFileSync(TOML, "utf8");
  assert.match(toml, /^workers_dev\s*=\s*false\s*$/m);
  const limits = ratelimitConfig();
  assert.equal(limits.TELEMETRY_LIMIT?.limit, 6, "telemetria: 6 eventi al minuto");
  assert.equal(limits.TELEMETRY_LIMIT?.period, 60);
  assert.ok(limits.FEEDBACK_LIMIT, "manca il rate limit del feedback");
  assert.ok(limits.ALERT_LIMIT, "manca il tetto degli avvisi Telegram");
  const ids = [...toml.matchAll(/namespace_id\s*=\s*"(\d+)"/g)].map((m) => m[1]);
  assert.equal(new Set(ids).size, ids.length, "ogni rate limit vuole il suo namespace_id");
});

// MARK: - Download

test("download: stessa rete IPv6 /64 = un solo avviso", async () => {
  const { env, sent } = setup();
  await call(env, { path: "/download/windows", ip: "2001:db8:1:2::1" });
  await call(env, { path: "/download/windows", ip: "2001:db8:1:2:ffff:ffff:ffff:9" });
  await call(env, { path: "/download/windows", ip: "2001:0db8:0001:0002:0:0:0:abcd" });
  assert.equal(sent.telegram.length, 1);
  await call(env, { path: "/download/windows", ip: "2001:db8:1:3::1" });
  assert.equal(sent.telegram.length, 2, "un'altra /64 è un altro visitatore");
});

test("download: tetto globale agli avvisi anche da indirizzi tutti diversi", async () => {
  const { env, sent, limits } = setup();
  for (let i = 1; i <= 20; i++) await call(env, { path: "/download", ip: `198.51.100.${i}` });
  assert.ok(limits.ALERT_LIMIT, "manca ALERT_LIMIT");
  assert.equal(sent.telegram.length, limits.ALERT_LIMIT.limit);
});

test("download: Plausible conta solo GET di un browser", async () => {
  const { env, sent } = setup();
  await call(env, { path: "/download", method: "HEAD" });
  await call(env, { path: "/download", agent: "curl/8.7.1" });
  await call(env, { path: "/download", agent: "" });
  assert.equal(sent.plausible.length, 0, "HEAD, curl e richieste senza user-agent non sono download");
  await call(env, { path: "/download" });
  assert.equal(sent.plausible.length, 1);
});

test("download: HEAD non manda avvisi", async () => {
  const { env, sent } = setup();
  await call(env, { path: "/download", method: "HEAD" });
  assert.equal(sent.telegram.length, 0);
});

// MARK: - Feedback

test("feedback: il rate limit non scrive l'IP in KV e usa una chiave hash per /64", async () => {
  const { env, limiters } = setup();
  const ip = "2001:db8:aaaa:bbbb::42";
  const response = await call(env, { path: "/api/feedback", method: "POST", ip, body: feedback() });
  assert.equal(response.status, 200);
  for (const { key, value } of env.FEEDBACK.puts) {
    assert.ok(!key.startsWith("rl:"), `chiave di rate limit in KV: ${key}`);
    assert.ok(!key.includes("2001:db8") && !String(value).includes("2001:db8"), "l'IP è finito in KV");
  }
  assert.ok(limiters.FEEDBACK_LIMIT, "manca FEEDBACK_LIMIT");
  assert.equal(limiters.FEEDBACK_LIMIT.keys.length, 1);
  assert.ok(!limiters.FEEDBACK_LIMIT.keys[0].includes("2001"), "la chiave del rate limit contiene l'IP in chiaro");
});

test("feedback: una raffica dalla stessa /64 si ferma al limite", async () => {
  const { env, limits } = setup();
  const statuses = [];
  for (let i = 1; i <= 10; i++) {
    const r = await call(env, { path: "/api/feedback", method: "POST", ip: `2001:db8:aaaa:bbbb::${i}`, body: feedback() });
    statuses.push(r.status);
  }
  assert.ok(limits.FEEDBACK_LIMIT, "manca FEEDBACK_LIMIT");
  assert.equal(statuses.filter((s) => s === 200).length, limits.FEEDBACK_LIMIT.limit);
  assert.ok(statuses.includes(429));
});

test("feedback: corpo oltre MAX_BODY rifiutato", async () => {
  const { env } = setup();
  const big = { ...feedback(), diagnostics: "x".repeat(60_000) };
  const response = await call(env, { path: "/api/feedback", method: "POST", body: big });
  assert.equal(response.status, 413);
});

test("feedback: la diagnostica normale passa ancora", async () => {
  const { env } = setup();
  const normal = { ...feedback(), diagnostics: "riga di log abbastanza lunga per sembrare vera\n".repeat(400) };
  const response = await call(env, { path: "/api/feedback", method: "POST", body: normal });
  assert.equal(response.status, 200);
});

test("feedback: tetto globale anche agli avvisi del feedback", async () => {
  const { env, sent, limits } = setup();
  for (let i = 1; i <= 12; i++) {
    const r = await call(env, { path: "/api/feedback", method: "POST", ip: `198.51.100.${i}`, body: feedback(`Messaggio numero ${i}`) });
    assert.equal(r.status, 200);
  }
  assert.equal(env.FEEDBACK.puts.filter((p) => p.key.startsWith("fb:")).length, 12, "i feedback si salvano tutti");
  assert.ok(limits.ALERT_LIMIT, "manca ALERT_LIMIT");
  assert.equal(sent.telegram.length, limits.ALERT_LIMIT.limit);
});

// MARK: - Telemetria

test("telemetria: un solo avvio per installazione al giorno", async () => {
  const { env } = setup();
  for (let i = 0; i < 3; i++) {
    const r = await call(env, { path: "/api/t", method: "POST", ip: `198.51.100.${i + 1}`, body: event("avvio") });
    assert.equal(r.status, 200);
  }
  const r = await call(env, { path: "/api/t", method: "POST", ip: "198.51.100.9", body: event("registrazione") });
  assert.equal(r.status, 200);
  const rows = env.TELEMETRY.db.prepare("SELECT evento, COUNT(*) AS n FROM eventi GROUP BY evento ORDER BY evento").all();
  assert.deepEqual(rows.map((x) => ({ ...x })), [{ evento: "avvio", n: 1 }, { evento: "registrazione", n: 1 }]);
});

test("telemetria: limite per /64, non per singolo indirizzo", async () => {
  const { env, limits, limiters } = setup();
  const statuses = [];
  for (let i = 1; i <= limits.TELEMETRY_LIMIT.limit + 1; i++) {
    const r = await call(env, { path: "/api/t", method: "POST", ip: `2001:db8:5:6::${i}`, body: event("registrazione") });
    statuses.push(r.status);
  }
  assert.equal(statuses.at(-1), 429);
  assert.ok(limiters.TELEMETRY_LIMIT.keys.every((k) => !k.includes("2001")), "chiave del rate limit con l'IP in chiaro");
});

test("migration 0002 si applica anche con avvii doppi già salvati", () => {
  const db = new DatabaseSync(":memory:");
  const dir = join(WORKER_DIR, "migrations");
  const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
  db.exec(readFileSync(join(dir, files[0]), "utf8"));
  const insert = db.prepare("INSERT INTO eventi (ts, evento, piattaforma, versione, installazione) VALUES (?, 'avvio', 'macos', '0.3.4', ?)");
  insert.run("2026-10-16T08:00:00.000Z", INSTALL);
  insert.run("2026-10-16T09:00:00.000Z", INSTALL);
  for (const file of files.slice(1)) db.exec(readFileSync(join(dir, file), "utf8"));
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM eventi").get().n, 2, "la migration non cancella dati");
});

test("addressPrefix: IPv4 intero, IPv6 alla /64", async () => {
  const { addressPrefix } = await import(pathToFileURL(MODULE).href);
  assert.equal(addressPrefix("203.0.113.7"), "203.0.113.7");
  assert.equal(addressPrefix("2001:db8:1:2::1"), "2001:0db8:0001:0002::/64");
  assert.equal(addressPrefix("2001:DB8:1:2:ffff:ffff:ffff:9"), "2001:0db8:0001:0002::/64");
  assert.equal(addressPrefix("::1"), "0000:0000:0000:0000::/64");
  assert.equal(addressPrefix("2001:db8::"), "2001:0db8:0000:0000::/64");
  assert.equal(addressPrefix("::ffff:198.51.100.4"), "198.51.100.4");
  assert.equal(addressPrefix("64:ff9b::198.51.100.4"), "0064:ff9b:0000:0000::/64");
  assert.equal(addressPrefix("non-un-indirizzo:::"), "non-un-indirizzo:::", "un valore strano resta com'è");
  assert.equal(addressPrefix(""), "");
});

// MARK: - Pagine HTML

test("pagine: no-transform e gzip fatto dal Worker", async () => {
  const { env } = setup();
  for (const path of ["/", "/en/", "/privacy/", "/en/privacy/"]) {
    const r = await call(env, { path, headers: { "accept-encoding": "gzip, br" } });
    assert.match(r.headers.get("cache-control"), /no-transform/, path);
    assert.equal(r.headers.get("content-encoding"), "gzip", path);
    const testo = await new Response(r.body.pipeThrough(new DecompressionStream("gzip"))).text();
    assert.equal(testo, PAGINA_FINTA, path);
  }
});

test("pagine: senza gzip nella richiesta il corpo esce in chiaro, sempre con no-transform", async () => {
  const { env } = setup();
  const r = await call(env, { path: "/" });
  assert.equal(r.headers.get("content-encoding"), null);
  assert.match(r.headers.get("cache-control"), /no-transform/);
  assert.equal(await r.text(), PAGINA_FINTA);
});

test("pagine: wrangler.toml manda al Worker tutte le pagine di PAGINE", () => {
  const toml = readFileSync(TOML, "utf8");
  for (const path of ["/", "/en/", "/privacy/", "/en/privacy/"]) assert.match(toml, new RegExp(`"${path.replace(/\//g, "\\/")}"`));
});
