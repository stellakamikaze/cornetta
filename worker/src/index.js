// Worker di Cornetta: riceve i feedback dall'app e serve pagina, DMG e feed degli aggiornamenti.
// I file statici stanno in ../public; qui passano solo le richieste /api/*.

const MAX_BODY = 100_000;
const MAX_PER_HOUR = 20;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/api/feedback") {
      if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors() });
      if (request.method !== "POST") return json({ ok: false, error: "Usa POST" }, 405);
      return saveFeedback(request, env);
    }
    if (url.pathname === "/api/health") return json({ ok: true });
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
    app: pick(body.app, ["version", "build", "macOS", "arch", "microphone"]),
    diagnostics: typeof body.diagnostics === "string" ? body.diagnostics.slice(0, 60_000) : "",
    country: request.cf?.country || "",
  };
  await env.FEEDBACK.put(id, JSON.stringify(record), {
    metadata: { preview: message.slice(0, 120), version: record.app.version || "", status: "nuovo" },
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

function cors() {
  return { "access-control-allow-origin": "*", "access-control-allow-methods": "POST, OPTIONS", "access-control-allow-headers": "content-type" };
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json; charset=utf-8", ...cors() } });
}
