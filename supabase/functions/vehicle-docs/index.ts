// ============================================================
//  vehicle-docs — Supabase Edge Function
//  Uploads, opens and deletes the documents attached to a truck
//  (registrations, receipts, insurance cards, ...).
//  Every request must carry the 4-digit Reports PIN; the function checks it
//  against the database before it touches a file. Files live in the PRIVATE
//  storage bucket "vehicle-docs" and are only handed out as links that
//  stop working after an hour.
//
//  Deploy: Supabase > Edge Functions > Deploy a new function > name it
//  exactly  vehicle-docs  > paste this file > Deploy.
//  No secret to add: Supabase gives every function SUPABASE_URL and
//  SUPABASE_SERVICE_ROLE_KEY automatically.
// ============================================================

const BUCKET = "vehicle-docs";
const MAX_BYTES = 15 * 1024 * 1024; // 15 MB per file
const LINK_SECONDS = 60 * 60;       // opened links work for 1 hour
const DOC_TYPES = ["Registration", "Receipt", "Insurance", "Inspection", "Title", "Other"];

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

const URL_ = Deno.env.get("SUPABASE_URL") ?? "";
const KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const H = { apikey: KEY, Authorization: `Bearer ${KEY}` };

async function rest(path: string, init: RequestInit = {}) {
  const res = await fetch(`${URL_}${path}`, { ...init, headers: { ...H, "Content-Type": "application/json", ...(init.headers ?? {}) } });
  const text = await res.text();
  let data: unknown = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  if (!res.ok) throw new Error(typeof data === "object" && data && "message" in data ? String((data as { message: unknown }).message) : text || res.statusText);
  return data;
}

async function pinOk(pin: string) {
  if (!/^[0-9]{4}$/.test(pin)) return false;
  return (await rest("/rest/v1/rpc/check_pin", { method: "POST", body: JSON.stringify({ p_pin: pin }) })) === true;
}

function b64ToBytes(b64: string) {
  const bin = atob(b64.replace(/^data:[^,]*,/, ""));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function safeName(s: string) {
  return (s || "file").replace(/[^A-Za-z0-9._-]+/g, "_").replace(/^_+|_+$/g, "").slice(0, 80) || "file";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (!URL_ || !KEY) return json({ ok: false, error: "function is missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY" });

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ ok: false, error: "bad request" }, 400); }

  try {
    if (!(await pinOk(String(body.pin ?? "")))) return json({ ok: false, error: "wrong pin" }, 401);
    const action = String(body.action ?? "");

    // ---- upload one file to a truck ----
    if (action === "upload") {
      const code = String(body.code ?? "");
      const assets = await rest(`/rest/v1/assets?select=id&code=eq.${encodeURIComponent(code)}`) as { id: string }[];
      if (!assets.length) return json({ ok: false, error: `no truck with barcode ${code}` }, 404);
      const bytes = b64ToBytes(String(body.data ?? ""));
      if (!bytes.length) return json({ ok: false, error: "empty file" }, 400);
      if (bytes.length > MAX_BYTES) return json({ ok: false, error: "file is over 15 MB" }, 413);
      const mime = String(body.mime ?? "") || "application/octet-stream";
      const fileName = safeName(String(body.fileName ?? ""));
      const path = `${safeName(code)}/${crypto.randomUUID()}-${fileName}`;

      const up = await fetch(`${URL_}/storage/v1/object/${BUCKET}/${path}`, {
        method: "POST", headers: { ...H, "Content-Type": mime, "x-upsert": "false" }, body: bytes,
      });
      if (!up.ok) return json({ ok: false, error: `storage: ${await up.text()}` }, 500);

      const docType = DOC_TYPES.includes(String(body.docType)) ? String(body.docType) : "Other";
      const maintId = /^[0-9a-f-]{36}$/i.test(String(body.maintId ?? "")) ? String(body.maintId) : null;
      const rows = await rest("/rest/v1/vehicle_docs", {
        method: "POST", headers: { Prefer: "return=representation" },
        body: JSON.stringify({
          asset_id: assets[0].id, doc_type: docType, title: String(body.title ?? "").trim().slice(0, 120),
          file_path: path, mime, size_bytes: bytes.length, maint_id: maintId,
        }),
      }) as unknown[];
      return json({ ok: true, doc: rows[0] });
    }

    // ---- short-lived links to open / preview files ----
    if (action === "sign") {
      const paths = (Array.isArray(body.paths) ? body.paths : []).map(String).filter(Boolean).slice(0, 100);
      if (!paths.length) return json({ ok: true, urls: {} });
      const signed = await rest(`/storage/v1/object/sign/${BUCKET}`, {
        method: "POST", body: JSON.stringify({ expiresIn: LINK_SECONDS, paths }),
      }) as { path: string; signedURL: string | null }[];
      const urls: Record<string, string> = {};
      for (const s of signed) if (s.signedURL) urls[s.path] = `${URL_}/storage/v1${s.signedURL}`;
      return json({ ok: true, urls });
    }

    // ---- delete a file ----
    if (action === "delete") {
      const id = String(body.id ?? "");
      if (!/^[0-9a-f-]{36}$/i.test(id)) return json({ ok: false, error: "bad id" }, 400);
      const rows = await rest(`/rest/v1/vehicle_docs?select=file_path&id=eq.${id}`) as { file_path: string }[];
      if (rows.length) {
        await rest(`/storage/v1/object/${BUCKET}`, { method: "DELETE", body: JSON.stringify({ prefixes: [rows[0].file_path] }) });
        await rest(`/rest/v1/vehicle_docs?id=eq.${id}`, { method: "DELETE" });
      }
      return json({ ok: true });
    }

    return json({ ok: false, error: "unknown action" }, 400);
  } catch (e) {
    return json({ ok: false, error: String(e instanceof Error ? e.message : e) }, 500);
  }
});
