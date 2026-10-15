// Worker di Cornetta: riceve feedback e telemetria dalle app, conta visite e download,
// e serve pagina, DMG e feed degli aggiornamenti.
// I file statici stanno in ../public; qui passano solo /api/*, /js/p.js e /download*.

const MAX_BODY = 100_000;
const MAX_PER_HOUR = 20;
const KEEP_SECONDS = 90 * 24 * 3600;   // i feedback si cancellano da soli dopo 90 giorni (scripts/feedback.py legge questa riga)

const SITE = "cornetta.stellakamikaze.org";
const PLAUSIBLE = "https://analytics.stellakamikaze.org";
const TELEMETRY_KEEP_DAYS = 365;

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
      ctx.waitUntil(countDownload(request, url.pathname === "/download" ? "macos" : "windows"));
      return env.ASSETS.fetch(request);
    }
    if (url.pathname === "/api/feedback") {
      if (request.method !== "POST") return json({ ok: false, error: "Usa POST" }, 405, { allow: "POST" });
      // Il feedback arriva solo dalle app native: un browser manda sempre Origin e qui viene rifiutato.
      if (request.headers.get("origin")) return json({ ok: false, error: "Non accettato" }, 403);
      if (!(request.headers.get("content-type") || "").startsWith("application/json")) {
        return json({ ok: false, error: "Serve application/json" }, 415);
      }
      return saveFeedback(request, env);
    }
    if (url.pathname === "/api/health") return json({ ok: true });
    if (url.pathname.startsWith("/api/")) return json({ ok: false, error: "Non trovato" }, 404);
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
  const ip = request.headers.get("cf-connecting-ip") || "sconosciuto";
  const { success } = await env.TELEMETRY_LIMIT.limit({ key: ip });
  if (!success) return json({ ok: false, error: "Troppi eventi" }, 429);
  const raw = await request.text();
  if (raw.length > 2000) return json({ ok: false, error: "Evento troppo lungo" }, 413);
  let body;
  try { body = JSON.parse(raw); } catch { return json({ ok: false, error: "JSON non valido" }, 400); }
  const e = validateTelemetry(body);
  if (!e) return json({ ok: false, error: "Evento non valido" }, 400);
  try {
    await env.TELEMETRY.prepare(
      "INSERT INTO eventi (ts, evento, piattaforma, versione, os, arch, paese, installazione, esito, codice, durata) VALUES (?,?,?,?,?,?,?,?,?,?,?)"
    ).bind(new Date().toISOString(), e.evento, e.piattaforma, e.versione, e.os, e.arch,
      request.cf?.country || "", e.installazione, e.esito, e.codice, e.durata).run();
  } catch {
    return json({ ok: false, error: "Archivio non disponibile" }, 503);
  }
  return json({ ok: true });
}

// MARK: - Statistiche delle visite (Plausible, senza cookie)

function plausibleHeaders(request) {
  // L'IP reale va nell'X-Forwarded-For: Plausible lo usa solo per l'hash giornaliero dei visitatori, non lo salva.
  return {
    "user-agent": request.headers.get("user-agent") || "",
    "x-forwarded-for": request.headers.get("cf-connecting-ip") || "",
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
  const body = JSON.stringify({
    name: "Download",
    url: `https://${SITE}${new URL(request.url).pathname}`,
    domain: SITE,
    referrer: request.headers.get("referer") || "",
    props: { piattaforma: platform },
  });
  try { await fetch(PLAUSIBLE + "/api/event", { method: "POST", headers: plausibleHeaders(request), body }); } catch {}
}

async function saveFeedback(request, env) {
  const length = Number(request.headers.get("content-length") || 0);
  if (length > MAX_BODY) return json({ ok: false, error: "Messaggio troppo lungo" }, 413);

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

  // Limite per indirizzo IP: protegge l'archivio da invii a raffica.
  const ip = request.headers.get("cf-connecting-ip") || "sconosciuto";
  const hour = new Date().toISOString().slice(0, 13);
  const rateKey = `rl:${ip}:${hour}`;
  try {
    const count = Number((await env.FEEDBACK.get(rateKey)) || 0);
    if (count >= MAX_PER_HOUR) return json({ ok: false, error: "Troppi invii, riprova tra un'ora" }, 429);
    await env.FEEDBACK.put(rateKey, String(count + 1), { expirationTtl: 3600 });
  } catch {
    return json({ ok: false, error: "Archivio non disponibile, riprova tra poco" }, 503);
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
    diagnostics: typeof body.diagnostics === "string" ? clean(body.diagnostics).slice(0, 60_000) : "",
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
