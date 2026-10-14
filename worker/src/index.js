// Worker di Cornetta: riceve i feedback dall'app e serve pagina, DMG e feed degli aggiornamenti.
// I file statici stanno in ../public; qui passano solo le richieste /api/*.

const MAX_BODY = 100_000;
const MAX_PER_HOUR = 20;
const KEEP_SECONDS = 90 * 24 * 3600;   // i feedback si cancellano da soli dopo 90 giorni

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
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
};

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
