// Worker di Cornetta: riceve i feedback dall'app e serve pagina, DMG e feed degli aggiornamenti.
// I file statici stanno in ../public; qui passano solo le richieste /api/*.

const MAX_BODY = 100_000;
const MAX_PER_HOUR = 20;

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
  const message = typeof body.message === "string" ? body.message.trim() : "";
  if (message.length < 2 || message.length > 10_000) {
    return json({ ok: false, error: "Scrivi un messaggio (massimo 10.000 caratteri)" }, 400);
  }

  // Limite per indirizzo IP: protegge l'archivio da invii a raffica.
  const ip = request.headers.get("cf-connecting-ip") || "sconosciuto";
  const hour = new Date().toISOString().slice(0, 13);
  const rateKey = `rl:${ip}:${hour}`;
  const count = Number((await env.FEEDBACK.get(rateKey)) || 0);
  if (count >= MAX_PER_HOUR) return json({ ok: false, error: "Troppi invii, riprova tra un'ora" }, 429);
  await env.FEEDBACK.put(rateKey, String(count + 1), { expirationTtl: 3600 });

  const now = new Date().toISOString();
  const id = `fb:${now}:${crypto.randomUUID().slice(0, 8)}`;
  const record = {
    id,
    receivedAt: now,
    message,
    email: typeof body.email === "string" ? body.email.trim().slice(0, 200) : "",
    name: typeof body.name === "string" ? body.name.trim().slice(0, 100) : "",
    platform: body.platform === "windows" ? "windows" : "macos",
    app: pick(body.app, ["version", "build", "macOS", "os", "arch", "microphone"]),
    diagnostics: typeof body.diagnostics === "string" ? body.diagnostics.slice(0, 60_000) : "",
    country: request.cf?.country || "",
  };
  await env.FEEDBACK.put(id, JSON.stringify(record), {
    metadata: { preview: message.slice(0, 120), version: record.app.version || "", platform: record.platform, status: "nuovo" },
  });
  return json({ ok: true, id });
}

function pick(value, keys) {
  const out = {};
  if (value && typeof value === "object") {
    for (const k of keys) if (typeof value[k] === "string") out[k] = value[k].slice(0, 200);
  }
  return out;
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
