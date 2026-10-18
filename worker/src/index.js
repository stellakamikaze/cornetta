// Worker di Cornetta: riceve feedback e telemetria dalle app, conta visite e download,
// e serve pagina, DMG e feed degli aggiornamenti.
// I file statici stanno in ../public; qui passano solo /api/*, /js/p.js, /download* e le pagine HTML.

// Tetto del corpo del feedback: un messaggio fino a 10.000 caratteri più la diagnostica (120 righe di log).
const MAX_BODY = 48_000;
const KEEP_SECONDS = 90 * 24 * 3600;   // i feedback si cancellano da soli dopo 90 giorni (scripts/feedback.py legge questa riga)

const SITE = "cornetta.stellakamikaze.org";
const PLAUSIBLE = "https://analytics.stellakamikaze.org";
const TELEMETRY_KEEP_DAYS = 365;

// Le pagine HTML escono con no-transform: così Cloudflare non inietta lo script
// anti-bot (JavaScript Detections, che sul piano Free non si spegne) e la CSP
// resta script-src 'self'. no-transform toglie anche la compressione dell'edge,
// quindi il gzip lo fa il Worker. Una pagina nuova va qui e in run_worker_first.
const PAGINE = new Set(["/", "/en/", "/privacy/", "/en/privacy/"]);

async function pagina(request, env) {
  const r = await env.ASSETS.fetch(request);
  if (r.status !== 200 || !(r.headers.get("content-type") || "").startsWith("text/html")) return r;
  const headers = new Headers(r.headers);
  headers.set("cache-control", "public, max-age=0, must-revalidate, no-transform");
  headers.append("vary", "accept-encoding");
  const accetta = request.cf?.clientAcceptEncoding ?? request.headers.get("accept-encoding") ?? "";
  if (request.method === "HEAD" || !/\bgzip\b/.test(accetta)) return new Response(r.body, { status: 200, headers });
  headers.set("content-encoding", "gzip");
  headers.delete("content-length");
  return new Response(r.body.pipeThrough(new CompressionStream("gzip")), { status: 200, headers, encodeBody: "manual" });
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === "/api/t") {
      if (request.method !== "POST") return json({ ok: false, error: "Usa POST" }, 405, { allow: "POST" });
      if (request.headers.get("origin")) return json({ ok: false, error: "Non accettato" }, 403);
      if (!(request.headers.get("content-type") || "").startsWith("application/json")) {
        return json({ ok: false, error: "Serve application/json" }, 415);
      }
      return saveTelemetry(request, env);
    }
    // Statistiche delle visite: Plausible sul server di Federico, servito da qui perché gli adblock non lo taglino.
    if (url.pathname === "/js/p.js") return plausibleScript(request);
    if (url.pathname === "/api/e") return plausibleEvent(request);
    if (url.pathname === "/download" || url.pathname === "/download/windows") {
      const platform = url.pathname === "/download" ? "macos" : "windows";
      ctx.waitUntil(countDownload(request, platform));
      ctx.waitUntil(announceDownload(request, env, platform));
      return env.ASSETS.fetch(request);
    }
    if (url.pathname === "/api/feedback") {
      if (request.method !== "POST") return json({ ok: false, error: "Usa POST" }, 405, { allow: "POST" });
      // Il feedback arriva solo dalle app native: un browser manda sempre Origin e qui viene rifiutato.
      if (request.headers.get("origin")) return json({ ok: false, error: "Non accettato" }, 403);
      if (!(request.headers.get("content-type") || "").startsWith("application/json")) {
        return json({ ok: false, error: "Serve application/json" }, 415);
      }
      return saveFeedback(request, env, ctx);
    }
    if (url.pathname === "/api/health") return json({ ok: true });
    if (url.pathname.startsWith("/api/")) return json({ ok: false, error: "Non trovato" }, 404);
    if (PAGINE.has(url.pathname)) return pagina(request, env);
    return env.ASSETS.fetch(request);
  },

  async scheduled(event, env) {
    const limit = new Date(Date.now() - TELEMETRY_KEEP_DAYS * 86400_000).toISOString();
    await env.TELEMETRY.prepare("DELETE FROM eventi WHERE ts < ?").bind(limit).run();
  },
};

// MARK: - Telemetria di funzionamento
// Lista chiusa: un campo o un valore fuori lista fa rifiutare l'evento. Niente audio, testi, nomi di file,
// dispositivi o IP: solo come sta andando l'app. Lo spiega la pagina /privacy.

const EVENTS = ["avvio", "registrazione", "trascrizione", "aggiornamento"];
const PLATFORMS = ["macos", "windows"];
const OUTCOMES = ["", "ok", "errore", "annullata"];
const DURATIONS = ["", "<1m", "1-5m", "5-15m", "15-60m", ">60m"];

export function validateTelemetry(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) return null;
  const allowed = ["evento", "piattaforma", "versione", "os", "arch", "installazione", "esito", "codice", "durata"];
  if (Object.keys(body).some((k) => !allowed.includes(k))) return null;
  const text = (k) => (body[k] === undefined ? "" : body[k]);
  if (Object.values(body).some((v) => typeof v !== "string")) return null;
  const e = {
    evento: text("evento"), piattaforma: text("piattaforma"), versione: text("versione"),
    os: text("os"), arch: text("arch"), installazione: text("installazione"),
    esito: text("esito"), codice: text("codice"), durata: text("durata"),
  };
  if (!EVENTS.includes(e.evento) || !PLATFORMS.includes(e.piattaforma)) return null;
  if (!/^\d{1,3}\.\d{1,3}\.\d{1,5}$/.test(e.versione)) return null;
  if (!/^[A-Za-z0-9 ._()-]{0,40}$/.test(e.os)) return null;
  if (!/^[a-z0-9_]{0,12}$/.test(e.arch)) return null;
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(e.installazione)) return null;
  if (!OUTCOMES.includes(e.esito) || !DURATIONS.includes(e.durata)) return null;
  if (!/^[A-Za-z0-9_.-]{0,60}$/.test(e.codice)) return null;
  return e;
}

async function saveTelemetry(request, env) {
  const { success } = await env.TELEMETRY_LIMIT.limit({ key: await addressKey("telemetria", request) });
  if (!success) return json({ ok: false, error: "Troppi eventi" }, 429);
  const raw = await request.text();
  if (raw.length > 2000) return json({ ok: false, error: "Evento troppo lungo" }, 413);
  let body;
  try { body = JSON.parse(raw); } catch { return json({ ok: false, error: "JSON non valido" }, 400); }
  const e = validateTelemetry(body);
  if (!e) return json({ ok: false, error: "Evento non valido" }, 400);
  // Un solo «avvio» per installazione al giorno: l'indice unico eventi_avvio_giorno (migration 0002)
  // scarta i doppioni, e INSERT OR IGNORE li salta senza errore.
  const ts = new Date().toISOString();
  const day = e.evento === "avvio" ? ts.slice(0, 10) : null;
  try {
    await env.TELEMETRY.prepare(
      "INSERT OR IGNORE INTO eventi (ts, evento, piattaforma, versione, os, arch, paese, installazione, esito, codice, durata, giorno) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)"
    ).bind(ts, e.evento, e.piattaforma, e.versione, e.os, e.arch,
      request.cf?.country || "", e.installazione, e.esito, e.codice, e.durata, day).run();
  } catch {
    return json({ ok: false, error: "Archivio non disponibile" }, 503);
  }
  return json({ ok: true });
}

// MARK: - Indirizzi
// I limiti e il dedup degli avvisi usano l'IPv4 intero o la rete /64 di un IPv6: una casa o un server
// ha una /64 intera e può cambiare indirizzo a ogni richiesta. La chiave è un hash: l'indirizzo non
// esce dal Worker e non si salva da nessuna parte.

function ipv6Groups(ip) {
  const parts = ip.toLowerCase().split("%")[0].split("::");
  if (parts.length > 2) return null;
  const head = parts[0] ? parts[0].split(":") : [];
  const tail = parts.length === 2 && parts[1] ? parts[1].split(":") : [];
  const last = tail.length ? tail : head;
  if (last.length && last[last.length - 1].includes(".")) {
    const octets = last.pop().split(".").map(Number);
    if (octets.length !== 4 || octets.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) return null;
    last.push(((octets[0] << 8) | octets[1]).toString(16), ((octets[2] << 8) | octets[3]).toString(16));
  }
  const missing = 8 - head.length - tail.length;
  if (parts.length === 1 ? missing !== 0 : missing < 1) return null;
  const groups = [...head, ...Array(parts.length === 2 ? missing : 0).fill("0"), ...tail];
  if (groups.some((g) => !/^[0-9a-f]{1,4}$/.test(g))) return null;
  return groups.map((g) => g.padStart(4, "0"));
}

/** IPv4 intero, IPv6 ridotto alla sua /64 («2001:0db8:0001:0002::/64»). */
export function addressPrefix(ip) {
  if (!ip || !ip.includes(":")) return ip || "";
  const groups = ipv6Groups(ip);
  if (!groups) return ip;
  if (groups.slice(0, 5).every((g) => g === "0000") && groups[5] === "ffff") {
    // IPv4 scritto come IPv6 (::ffff:a.b.c.d): conta come l'IPv4.
    const n = parseInt(groups[6] + groups[7], 16);
    return [n >>> 24, (n >>> 16) & 255, (n >>> 8) & 255, n & 255].join(".");
  }
  return groups.slice(0, 4).join(":") + "::/64";
}

async function sha256Hex(text, bytes = 16) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].slice(0, bytes).map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Chiave per limiti e dedup: hash di uso e indirizzo (o /64), mai l'indirizzo in chiaro. */
async function addressKey(use, request) {
  return sha256Hex(`${use}:${addressPrefix(request.headers.get("cf-connecting-ip") || "")}`);
}

// MARK: - Avvisi su Telegram (@autoarturobot)
// Un messaggio a Federico per ogni download di una persona e per ogni feedback. Secret TELEGRAM_TOKEN e
// TELEGRAM_CHAT: senza, non parte niente. Bot e crawler non contano, e lo stesso visitatore (IPv4 o /64)
// non si ripete per un'ora (Cache API, senza scritture in KV). Sopra il dedup c'è un tetto fisso per
// tipo di avviso (ALERT_LIMIT, chiave «download» o «feedback»): una raffica da indirizzi tutti diversi
// non intasa Telegram. Il binding conta per minuto e per località Cloudflare (la doc non offre di meglio).

const BOT_AGENT = /bot|crawl|spider|slurp|preview|curl|wget|python|httpx|aiohttp|go-http|java\/|okhttp|headless|lighthouse|monitor|uptime|scan|fetch|axios|node|libwww|facebookexternalhit|whatsapp|telegram/i;

export function looksHuman(request) {
  const agent = request.headers.get("user-agent") || "";
  if (!agent || BOT_AGENT.test(agent)) return false;
  if (request.cf?.verifiedBotCategory) return false;
  return /Mozilla\/5\.0/.test(agent);
}

async function firstInAnHour(key) {
  const cache = caches.default;
  const request = new Request(`https://avvisi.cornetta.invalid/${key}`);
  if (await cache.match(request)) return false;
  await cache.put(request, new Response("1", { headers: { "cache-control": "max-age=3600" } }));
  return true;
}

/** Vero se c'è ancora posto per un avviso di questo tipo nel minuto. Senza binding non parte niente. */
async function alertAllowed(env, kind) {
  if (!env.ALERT_LIMIT) return false;
  try {
    const { success } = await env.ALERT_LIMIT.limit({ key: kind });
    if (!success) console.log(`Avviso ${kind} saltato: tetto al minuto raggiunto`);
    return success;
  } catch {
    return false;
  }
}

async function telegram(env, text) {
  if (!env.TELEGRAM_TOKEN || !env.TELEGRAM_CHAT) return;
  try {
    const response = await fetch(`https://api.telegram.org/bot${env.TELEGRAM_TOKEN}/sendMessage`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ chat_id: env.TELEGRAM_CHAT, text, disable_web_page_preview: true }),
    });
    const result = await response.json().catch(() => ({}));
    console.log(result.ok ? `Telegram: messaggio ${result.result?.message_id} inviato` : `Telegram ha risposto ${response.status}`);
  } catch (e) {
    console.log("Telegram non raggiungibile", e && e.message);
  }
}

async function announceDownload(request, env, platform) {
  if (request.method !== "GET" || !looksHuman(request)) return;
  if (!(await firstInAnHour(await addressKey(`download:${platform}`, request)))) return;
  if (!(await alertAllowed(env, "download"))) return;
  let version = "";
  try {
    const latest = await (await env.ASSETS.fetch(new Request(`https://${SITE}/downloads/latest.json`))).json();
    version = latest[platform]?.version || "";
  } catch {}
  let from = "";
  try { from = new URL(request.headers.get("referer") || "").hostname; } catch {}
  const where = request.cf?.country || "";
  await telegram(env, `Cornetta: download per ${platform === "windows" ? "Windows" : "Mac"}${version ? " " + version : ""}`
    + (where ? `, da ${where}` : "") + (from && from !== SITE ? ` (arriva da ${from})` : ""));
}

// MARK: - Statistiche delle visite (Plausible, senza cookie)

function plausibleHeaders(request) {
  // L'IP reale va in X-Plausible-IP, che Plausible legge prima degli altri header (dietro il Worker CF-Connecting-IP
  // sarebbe quello di Cloudflare). Plausible lo usa solo per l'hash giornaliero dei visitatori e non lo salva.
  return {
    "user-agent": request.headers.get("user-agent") || "",
    "x-plausible-ip": request.headers.get("cf-connecting-ip") || "",
    "content-type": "application/json",
  };
}

async function plausibleScript(request) {
  const response = await fetch(PLAUSIBLE + "/js/script.js", { cf: { cacheTtl: 86400, cacheEverything: true } });
  if (!response.ok) return new Response("", { status: 204 });
  return new Response(response.body, {
    headers: { "content-type": "application/javascript; charset=utf-8", "cache-control": "public, max-age=86400" },
  });
}

async function plausibleEvent(request) {
  if (request.method !== "POST") return new Response(null, { status: 405, headers: { allow: "POST" } });
  const body = await request.text();
  if (body.length > 4000) return new Response(null, { status: 413 });
  try {
    const response = await fetch(PLAUSIBLE + "/api/event", { method: "POST", headers: plausibleHeaders(request), body });
    return new Response(null, { status: response.status === 202 ? 202 : response.status });
  } catch {
    return new Response(null, { status: 202 });
  }
}

async function countDownload(request, platform) {
  // Un download è un GET di un browser: HEAD, bot, crawler e script non contano (come per gli avvisi).
  if (request.method !== "GET" || !looksHuman(request)) return;
  const body = JSON.stringify({
    name: "Download",
    url: `https://${SITE}${new URL(request.url).pathname}`,
    domain: SITE,
    referrer: request.headers.get("referer") || "",
    props: { piattaforma: platform },
  });
  try { await fetch(PLAUSIBLE + "/api/event", { method: "POST", headers: plausibleHeaders(request), body }); } catch {}
}

async function saveFeedback(request, env, ctx) {
  const length = Number(request.headers.get("content-length") || 0);
  if (length > MAX_BODY) return json({ ok: false, error: "Messaggio troppo lungo" }, 413);

  // Limite per IPv4 o /64, col binding FEEDBACK_LIMIT: regge alle raffiche in parallelo e non salva
  // l'indirizzo (la chiave è un hash). Conta anche i tentativi non validi.
  const { success } = await env.FEEDBACK_LIMIT.limit({ key: await addressKey("feedback", request) });
  if (!success) return json({ ok: false, error: "Troppi invii, riprova tra qualche minuto" }, 429);

  const raw = await request.text();
  if (raw.length > MAX_BODY) return json({ ok: false, error: "Messaggio troppo lungo" }, 413);

  let body;
  try {
    body = JSON.parse(raw);
  } catch {
    return json({ ok: false, error: "JSON non valido" }, 400);
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return json({ ok: false, error: "JSON non valido" }, 400);
  }
  const message = typeof body.message === "string" ? clean(body.message).trim() : "";
  if (message.length < 2 || message.length > 10_000) {
    return json({ ok: false, error: "Scrivi un messaggio (massimo 10.000 caratteri)" }, 400);
  }

  const now = new Date().toISOString();
  const id = `fb:${now}:${crypto.randomUUID().slice(0, 8)}`;
  const record = {
    id,
    receivedAt: now,
    message,
    email: typeof body.email === "string" ? clean(body.email).trim().slice(0, 200) : "",
    name: typeof body.name === "string" ? clean(body.name).trim().slice(0, 100) : "",
    platform: body.platform === "windows" ? "windows" : "macos",
    app: pick(body.app, ["version", "build", "macOS", "os", "arch", "microphone"]),
    diagnostics: typeof body.diagnostics === "string" ? clean(body.diagnostics).slice(0, MAX_BODY) : "",
    country: request.cf?.country || "",
  };
  try {
    await env.FEEDBACK.put(id, JSON.stringify(record), {
      expirationTtl: KEEP_SECONDS,
      metadata: { preview: message.slice(0, 120), version: record.app.version || "", platform: record.platform, status: "nuovo" },
    });
  } catch {
    return json({ ok: false, error: "Archivio non disponibile, riprova tra poco" }, 503);
  }
  ctx.waitUntil(alertAllowed(env, "feedback").then((allowed) => allowed && telegram(env, [
    `Cornetta: feedback da ${record.platform === "windows" ? "Windows" : "Mac"} ${record.app.version || "?"}${record.country ? ", " + record.country : ""}`,
    `«${message.slice(0, 600)}${message.length > 600 ? "…" : ""}»`,
    record.email ? "Ha lasciato l'email per la risposta." : "",
    `scripts/feedback.py show ${id}`,
  ].filter(Boolean).join("\n"))));
  return json({ ok: true, id });
}

function pick(value, keys) {
  const out = {};
  if (value && typeof value === "object") {
    for (const k of keys) if (typeof value[k] === "string") out[k] = clean(value[k]).slice(0, 200);
  }
  return out;
}

// Toglie i caratteri di controllo (tranne a capo e tab): nel terminale di chi legge non devono fare danni.
function clean(text) {
  return text.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F\u202A-\u202E\u2066-\u2069]/g, "");
}

// Le risposte dell'API non si mettono in cache e non si caricano in pagine altrui.
const API_HEADERS = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store",
  "x-content-type-options": "nosniff",
  "content-security-policy": "default-src 'none'; frame-ancestors 'none'",
  "strict-transport-security": "max-age=63072000; includeSubDomains",
  "referrer-policy": "no-referrer",
  "cross-origin-resource-policy": "same-origin",
};

function json(data, status = 200, extra = {}) {
  return new Response(JSON.stringify(data), { status, headers: { ...API_HEADERS, ...extra } });
}
