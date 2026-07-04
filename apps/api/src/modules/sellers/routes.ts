import { Router, json } from "express";
import { createHash, timingSafeEqual } from "node:crypto";
import { z } from "zod";
import { supabaseAdmin } from "../../supabase";
import { stripe } from "../../stripe";
import { config } from "../../config";

export const sellersRouter = Router();

// Este router se monta ANTES del express.json global (index.ts) → trae su propio parser
// con límite mayor (2 MB) para las fotos del registro (WebP en base64).
sellersRouter.use(json({ limit: "2mb" }));

/** Compara dos secretos en tiempo constante (hash a longitud fija primero). */
function secretoIgual(a: string, b: string): boolean {
  const ha = createHash("sha256").update(a).digest();
  const hb = createHash("sha256").update(b).digest();
  return timingSafeEqual(ha, hb);
}

const claimSchema = z.object({
  token: z.string().min(20),
  email: z
    .string()
    .email()
    .transform((s) => s.trim().toLowerCase()),
  password: z.string().min(8).max(72), // 72 = límite de bcrypt en GoTrue
});

/**
 * POST /sellers/claim — CANJE de invitación (claim). AUTORIDAD del alta de vendedor.
 *
 * Es el punto service_role del flujo de invitación (ver docs/INVITACION_ACCESO.md y
 * el contrato en apps/web/src/lib/vendedor/claim-service.ts). Corre con la SECRET key
 * (bypassa RLS), por eso hace su PROPIA authz y no confía en nada del cliente:
 *   - Autorizado por un secreto de servicio (Bearer), NO por la anon key.
 *   - Revalida el token por su hash SHA-256 (nunca el token en claro en BD).
 *   - Idempotente: el respaldo real es UNIQUE(artesanos.user_id) + guardas .is(null)
 *     + un-solo-uso (invitaciones.usado_en, con UNIQUE(token_hash) detrás).
 *
 * Convención de respuesta (la consume claim-service.ts): los desenlaces de NEGOCIO
 * (expirada/usada/invalida/email_en_uso) responden HTTP 200 con { ok:false, code }
 * para que el web mapee el mensaje amable; solo lo INFRA (auth/config/inesperado)
 * usa 401/503/500. El camino feliz responde { ok:true, userId, artesanoId }.
 */
sellersRouter.post("/claim", async (req, res) => {
  // (0) Fail-closed: sin secreto configurado, el alta está apagada (no expuesta sin auth).
  if (!config.claimServiceToken) {
    return res.status(503).json({ ok: false, error: "Servicio de alta no configurado." });
  }

  // (1) authz de servicio: Authorization: Bearer <CLAIM_SERVICE_TOKEN>.
  const authz = req.header("authorization") ?? "";
  const provided = authz.startsWith("Bearer ") ? authz.slice(7) : "";
  if (!provided || !secretoIgual(provided, config.claimServiceToken)) {
    return res.status(401).json({ ok: false, error: "No autorizado." });
  }

  // (2) validar entrada.
  const parsed = claimSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(200).json({ ok: false, error: "Datos inválidos.", code: "invalida" });
  }
  const { token, email, password } = parsed.data;
  const tokenHash = createHash("sha256").update(token, "utf8").digest("hex");

  // (3) localizar la invitación por hash y validar su estado (service_role bypassa RLS).
  const { data: inv, error: eInv } = await supabaseAdmin
    .from("invitaciones")
    .select("id,artesano_id,expira_en,usado_en,revocada_en")
    .eq("token_hash", tokenHash)
    .maybeSingle();
  if (eInv) {
    console.error("[claim] select invitacion:", eInv.message);
    return res.status(500).json({ ok: false, error: "Error interno." });
  }
  if (!inv) return res.status(200).json({ ok: false, error: "Invitación no encontrada.", code: "invalida" });
  if (inv.revocada_en) return res.status(200).json({ ok: false, error: "Invitación revocada.", code: "invalida" });
  if (inv.usado_en) return res.status(200).json({ ok: false, error: "Invitación ya usada.", code: "usada" });
  if (new Date(inv.expira_en as string).getTime() <= Date.now()) {
    return res.status(200).json({ ok: false, error: "Invitación expirada.", code: "expirada" });
  }

  // (4) el artesano debe existir y NO tener cuenta aún (1:1).
  const { data: art, error: eArt } = await supabaseAdmin
    .from("artesanos")
    .select("id,user_id")
    .eq("id", inv.artesano_id)
    .maybeSingle();
  if (eArt || !art) {
    console.error("[claim] select artesano:", eArt?.message);
    return res.status(500).json({ ok: false, error: "Error interno." });
  }
  if (art.user_id) {
    await sellarInvitacion(inv.id);
    return res.status(200).json({ ok: false, error: "Este artesano ya tiene cuenta.", code: "usada" });
  }

  // (5) crear el usuario con email confirmado (sin SMTP).
  const { data: created, error: eCreate } = await supabaseAdmin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { artesano_id: inv.artesano_id },
  });
  if (eCreate || !created?.user) {
    const msg = eCreate?.message ?? "";
    const enUso = /already|registered|exists|duplicate/i.test(msg);
    console.error("[claim] createUser:", msg);
    return res.status(enUso ? 200 : 500).json({
      ok: false,
      error: enUso ? "Ese correo ya tiene una cuenta." : "No se pudo crear la cuenta.",
      code: enUso ? "email_en_uso" : undefined,
    });
  }
  const userId = created.user.id;

  // (6) ligar user_id (whitelist: SOLO user_id) condicionado a que siga NULL. La guarda
  // .is("user_id", null) + UNIQUE(artesanos.user_id) evita doble-vínculo en carreras;
  // si perdemos la carrera, limpiamos el user recién creado para no dejar huérfanos.
  // Al reclamar por primera vez, el artesano se ACTIVA (nace 'pausado'/inactivo desde
  // el alta del admin; ver 0010: status='activo' es lo que habilita su acceso). whitelist:
  // solo user_id + status; jamás toca oficio/semblanza/fiscales (eso lo pone el artesano/Stripe).
  const { data: linked, error: eLink } = await supabaseAdmin
    .from("artesanos")
    .update({ user_id: userId, status: "activo" })
    .eq("id", inv.artesano_id)
    .is("user_id", null)
    .select("id");
  if (eLink || !linked || linked.length === 0) {
    await supabaseAdmin.auth.admin.deleteUser(userId).catch(() => {});
    return res.status(200).json({ ok: false, error: "Este artesano ya tiene cuenta.", code: "usada" });
  }

  // (7) sellar la invitación como usada (un-solo-uso).
  await sellarInvitacion(inv.id);

  return res.json({ ok: true, userId, artesanoId: inv.artesano_id });
});

/** Marca la invitación como usada (best-effort; solo si aún no lo estaba). */
async function sellarInvitacion(id: string): Promise<void> {
  await supabaseAdmin
    .from("invitaciones")
    .update({ usado_en: new Date().toISOString() })
    .eq("id", id)
    .is("usado_en", null);
}

/**
 * POST /sellers/purge — ELIMINA la cuenta auth de un artesano (uso ADMIN: cuenta
 * comprometida / baja definitiva). Corre con service_role (auth.admin.deleteUser),
 * autorizado por el MISMO secreto de servicio que /claim (Bearer). Recibe
 * { artesanoId } y resuelve su user_id EN LA BD — nunca confía en un userId del
 * cliente, así no se puede pedir borrar un auth.user arbitrario. El borrado del
 * artesano en sí lo hace el panel (eliminar_artesano_seguro); esto solo mata el login.
 */
sellersRouter.post("/purge", async (req, res) => {
  if (!config.claimServiceToken) {
    return res.status(503).json({ ok: false, error: "Servicio no configurado." });
  }
  const authz = req.header("authorization") ?? "";
  const provided = authz.startsWith("Bearer ") ? authz.slice(7) : "";
  if (!provided || !secretoIgual(provided, config.claimServiceToken)) {
    return res.status(401).json({ ok: false, error: "No autorizado." });
  }
  const artesanoId = typeof req.body?.artesanoId === "string" ? req.body.artesanoId : "";
  if (!artesanoId) return res.status(400).json({ ok: false, error: "Falta artesanoId." });

  const { data: art, error: eArt } = await supabaseAdmin
    .from("artesanos")
    .select("user_id")
    .eq("id", artesanoId)
    .maybeSingle();
  if (eArt) {
    console.error("[purge] select artesano:", eArt.message);
    return res.status(500).json({ ok: false, error: "Error interno." });
  }
  const userId = (art?.user_id as string | null | undefined) ?? null;
  if (!userId) return res.json({ ok: true, hadAccount: false });

  const { error: eDel } = await supabaseAdmin.auth.admin.deleteUser(userId);
  if (eDel) {
    console.error("[purge] deleteUser:", eDel.message);
    return res.status(500).json({ ok: false, error: "No se pudo eliminar la cuenta." });
  }
  // Desligar por si el borrado del artesano no ocurriera después (defensa en profundidad).
  await supabaseAdmin.from("artesanos").update({ user_id: null }).eq("id", artesanoId);
  return res.json({ ok: true, hadAccount: true });
});

const registroSchema = z.object({
  token: z.string().min(20),
  email: z.string().email().transform((s) => s.trim().toLowerCase()),
  password: z.string().min(8).max(72),
  nombres: z.string().trim().min(1),
  apellidoP: z.string().trim().min(1),
  apellidoM: z.string().trim().optional().default(""),
  fechaNac: z.string().optional().default(""),
  telefono: z.string().trim().optional().default(""),
  tipoVendedor: z.enum(["persona", "taller", "tienda"]),
  nombreNegocio: z.string().trim().optional().default(""),
  // El wizard manda strings; "" (vacío) → undefined ANTES de coaccionar, si no
  // z.coerce.number() convierte "" en 0 y rompe .positive() (caso 'persona').
  numPersonas: z.preprocess(
    (v) => (v === "" || v == null ? undefined : v),
    z.coerce.number().int().positive().max(9999).optional(),
  ),
  ciudad: z.string().trim().optional().default(""),
  semblanza: z.string().max(2000).optional().default(""),
  oficio: z.string().trim().optional().default(""),
  region: z.string().trim().optional().default(""),
  instagram: z.string().trim().optional().default(""),
  sitio: z.string().trim().optional().default(""),
  aniosExp: z.preprocess(
    (v) => (v === "" || v == null ? undefined : v),
    z.coerce.number().int().nonnegative().max(120).optional(),
  ),
  enviaNacional: z.boolean().optional().default(false),
  // Fotos YA PROCESADAS (WebP) por el pipeline del web, en base64. Opcionales; se suben
  // DESPUÉS de crear el artesano (orphan-safe). Cota de tamaño = anti-DoS.
  fotoPerfilB64: z.string().max(3_000_000).optional(),
  fotoPortadaB64: z.string().max(3_000_000).optional(),
});

// Sube una foto YA procesada (WebP base64) a artesanos/<id>/ y devuelve su URL pública.
// Best-effort: nunca lanza. Solo se llama DESPUÉS de que el artesano existe → sin huérfanos.
async function subirFotoRegistro(
  artesanoId: string,
  tipo: "perfil" | "portada",
  b64?: string,
): Promise<string | null> {
  if (!b64) return null;
  try {
    const buffer = Buffer.from(b64, "base64");
    if (buffer.length === 0 || buffer.length > 2_500_000) return null;
    const path = `artesanos/${artesanoId}/${tipo}.webp`;
    const { error } = await supabaseAdmin.storage
      .from("piezas")
      .upload(path, buffer, { contentType: "image/webp", upsert: true });
    if (error) {
      console.error(`[register] subir ${tipo}:`, error.message);
      return null;
    }
    // URL RELATIVA same-origin (la sirve el rewrite del web). Host-portable.
    return `/storage/v1/object/public/piezas/${path}`;
  } catch (e) {
    console.error(`[register] foto ${tipo}:`, e instanceof Error ? e.message : e);
    return null;
  }
}

const slugify = (s: string) =>
  (s || "")
    .normalize("NFD").replace(/[̀-ͯ]/g, "")
    .toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 50) || "taller";

/**
 * POST /sellers/register — ENVÍO REAL del registro autoguiado. AUTORIDAD del alta:
 * service_role (bypassa RLS) + Bearer del secreto de servicio. Valida el link, crea el
 * auth.user, crea el artesano en estado 'pendiente' (NO accede hasta que el admin apruebe)
 * y consume la invitación (usado_en). Fotos: se suben después desde el panel (pendiente).
 * Respuestas de negocio con HTTP 200 + { ok:false, code } (mismo criterio que /claim).
 */
sellersRouter.post("/register", async (req, res) => {
  if (!config.claimServiceToken) return res.status(503).json({ ok: false, error: "Servicio no configurado." });
  const authz = req.header("authorization") ?? "";
  const provided = authz.startsWith("Bearer ") ? authz.slice(7) : "";
  if (!provided || !secretoIgual(provided, config.claimServiceToken)) {
    return res.status(401).json({ ok: false, error: "No autorizado." });
  }
  const parsed = registroSchema.safeParse(req.body);
  if (!parsed.success) {
    // Falla de DATOS (no del link): NO usar code:'invalida' (que el web mapea como enlace
    // inválido). Mostrar el motivo real del campo.
    const motivo = parsed.error.issues[0]?.message ?? "Revisa los datos.";
    return res.status(200).json({ ok: false, error: `Datos inválidos: ${motivo}` });
  }
  const d = parsed.data;
  const tokenHash = createHash("sha256").update(d.token, "utf8").digest("hex");

  // 1) Invitación de registro válida (no usada/revocada/expirada).
  const { data: inv, error: eInv } = await supabaseAdmin
    .from("invitaciones")
    .select("id,usado_en,revocada_en,expira_en")
    .eq("token_hash", tokenHash)
    .maybeSingle();
  if (eInv) { console.error("[register] inv:", eInv.message); return res.status(500).json({ ok: false, error: "Error interno." }); }
  if (!inv) return res.status(200).json({ ok: false, error: "Invitación no encontrada.", code: "invalida" });
  if (inv.revocada_en) return res.status(200).json({ ok: false, error: "Invitación revocada.", code: "invalida" });
  if (inv.usado_en) return res.status(200).json({ ok: false, error: "Invitación ya usada.", code: "usada" });
  if (new Date(inv.expira_en as string).getTime() <= Date.now())
    return res.status(200).json({ ok: false, error: "Invitación expirada.", code: "expirada" });

  // 2) Crear el usuario (email confirmado, sin SMTP).
  const { data: created, error: eCreate } = await supabaseAdmin.auth.admin.createUser({
    email: d.email, password: d.password, email_confirm: true,
  });
  if (eCreate || !created?.user) {
    const enUso = /already|registered|exists|duplicate/i.test(eCreate?.message ?? "");
    console.error("[register] createUser:", eCreate?.message);
    return res.status(enUso ? 200 : 500).json({ ok: false, error: enUso ? "Ese correo ya tiene una cuenta." : "No se pudo crear la cuenta.", code: enUso ? "email_en_uso" : undefined });
  }
  const userId = created.user.id;

  // 3) Nombre público (display) + slug único.
  const nombre = d.tipoVendedor !== "persona" && d.nombreNegocio
    ? d.nombreNegocio
    : `${d.nombres} ${d.apellidoP} ${d.apellidoM}`.replace(/\s+/g, " ").trim();
  let slug = slugify(nombre);
  const { data: existe } = await supabaseAdmin.from("artesanos").select("slug").ilike("slug", `${slug}%`);
  if ((existe ?? []).some((r) => (r as { slug: string }).slug === slug)) slug = `${slug}-${userId.slice(0, 6)}`;

  // 4) Artesano en estado 'pendiente' (whitelist: el servidor decide status/user_id/slug).
  const { data: art, error: eArt } = await supabaseAdmin
    .from("artesanos")
    .insert({
      slug, status: "pendiente", user_id: userId, nombre,
      nombres: d.nombres, apellido_paterno: d.apellidoP, apellido_materno: d.apellidoM || null,
      fecha_nacimiento: d.fechaNac || null, telefono: d.telefono || null,
      tipo_vendedor: d.tipoVendedor, nombre_negocio: d.nombreNegocio || null,
      num_personas: d.numPersonas ?? null, direccion: d.ciudad ? { ciudad: d.ciudad } : null,
      semblanza: d.semblanza || null, oficio: d.oficio || null, region: d.region || null,
      redes: (d.instagram || d.sitio) ? { instagram: d.instagram || null, sitio: d.sitio || null } : null,
      envia_nacional: d.enviaNacional, anios_experiencia: d.aniosExp ?? null,
    })
    .select("id")
    .maybeSingle();
  if (eArt || !art) {
    await supabaseAdmin.auth.admin.deleteUser(userId).catch(() => {}); // compensación
    console.error("[register] artesano:", eArt?.message);
    return res.status(500).json({ ok: false, error: "No se pudo crear tu perfil." });
  }
  const artesanoId = (art as { id: string }).id;

  // 4b) FOTOS (orphan-safe): el artesano YA existe → subimos las WebP procesadas a
  // artesanos/<id>/. Best-effort: si falla, queda sin foto, sin blobs huérfanos (van bajo
  // su carpeta y se limpian al borrar el artesano).
  const fotoUrl = await subirFotoRegistro(artesanoId, "perfil", d.fotoPerfilB64);
  const portadaUrl = await subirFotoRegistro(artesanoId, "portada", d.fotoPortadaB64);
  if (fotoUrl || portadaUrl) {
    await supabaseAdmin
      .from("artesanos")
      .update({ foto_url: fotoUrl ?? undefined, foto_portada: portadaUrl ?? undefined })
      .eq("id", artesanoId);
  }

  // 5) Consumir la invitación (un solo uso). Ligar el artesano creado.
  await supabaseAdmin
    .from("invitaciones")
    .update({ usado_en: new Date().toISOString(), artesano_id: artesanoId })
    .eq("id", inv.id)
    .is("usado_en", null);

  return res.json({ ok: true, userId, artesanoId });
});

// ── Helper de authz de servicio (Bearer del secreto compartido con el web) ──
function servicioAutorizado(req: import("express").Request): boolean {
  const authz = req.header("authorization") ?? "";
  const provided = authz.startsWith("Bearer ") ? authz.slice(7) : "";
  return Boolean(provided && config.claimServiceToken && secretoIgual(provided, config.claimServiceToken));
}

/**
 * POST /sellers/stripe/onboarding — FASE 2 (cobros). Crea (si no existe) la cuenta Connect
 * Express del artesano y devuelve un Account Link (onboarding HOSTED de Stripe, donde captura
 * sus datos fiscales/bancarios). service_role + Bearer. Modelo: separate charges & transfers →
 * la cuenta pide la capability `transfers` (recibe el neto que le dispersa la plataforma).
 */
sellersRouter.post("/stripe/onboarding", async (req, res) => {
  if (!config.stripeSecretKey) return res.status(503).json({ ok: false, error: "Stripe no configurado." });
  if (!servicioAutorizado(req)) return res.status(401).json({ ok: false, error: "No autorizado." });
  const artesanoId = typeof req.body?.artesanoId === "string" ? req.body.artesanoId : "";
  const email = typeof req.body?.email === "string" ? req.body.email : undefined;
  const returnUrl = typeof req.body?.returnUrl === "string" ? req.body.returnUrl : undefined;
  const refreshUrl = typeof req.body?.refreshUrl === "string" ? req.body.refreshUrl : undefined;
  if (!artesanoId) return res.status(400).json({ ok: false, error: "Falta artesanoId." });

  const { data: art, error } = await supabaseAdmin
    .from("artesanos").select("id,stripe_account_id").eq("id", artesanoId).maybeSingle();
  if (error || !art) return res.status(404).json({ ok: false, error: "Artesano no encontrado." });
  let accountId = (art as { stripe_account_id: string | null }).stripe_account_id;

  try {
    if (!accountId) {
      const account = await stripe().accounts.create({
        type: "express",
        country: "MX",
        email,
        capabilities: { transfers: { requested: true } },
      });
      accountId = account.id;
      await supabaseAdmin.from("artesanos").update({ stripe_account_id: accountId }).eq("id", artesanoId);
    }
    const link = await stripe().accountLinks.create({
      account: accountId,
      refresh_url: refreshUrl ?? returnUrl ?? "https://tlachiwalis.com/vendedor/cobros",
      return_url: returnUrl ?? "https://tlachiwalis.com/vendedor/cobros",
      type: "account_onboarding",
    });
    return res.json({ ok: true, url: link.url });
  } catch (e) {
    console.error("[stripe/onboarding]:", e instanceof Error ? e.message : e);
    return res.status(500).json({ ok: false, error: "No se pudo iniciar la conexión con Stripe." });
  }
});

/**
 * POST /sellers/stripe/estado — consulta la cuenta Connect y SINCRONIZA cobros_habilitados /
 * cobros_detalles_enviados (además del webhook account.updated, para reflejar al instante al
 * volver del onboarding). service_role + Bearer.
 */
sellersRouter.post("/stripe/estado", async (req, res) => {
  if (!config.stripeSecretKey) return res.status(503).json({ ok: false, error: "Stripe no configurado." });
  if (!servicioAutorizado(req)) return res.status(401).json({ ok: false, error: "No autorizado." });
  const artesanoId = typeof req.body?.artesanoId === "string" ? req.body.artesanoId : "";
  if (!artesanoId) return res.status(400).json({ ok: false, error: "Falta artesanoId." });

  const { data: art } = await supabaseAdmin
    .from("artesanos").select("stripe_account_id").eq("id", artesanoId).maybeSingle();
  const accountId = (art as { stripe_account_id: string | null } | null)?.stripe_account_id;
  if (!accountId) return res.json({ ok: true, conectado: false, cobrosHabilitados: false, detallesEnviados: false });

  try {
    const acct = await stripe().accounts.retrieve(accountId);
    // Modelo separate charges & transfers: la plataforma es el comercio, la cuenta del artesano
    // solo RECIBE transferencias → `charges_enabled` nunca se prende. La señal correcta de "puede
    // recibir su dinero" es payouts_enabled + capability transfers 'active'.
    const cobrosHabilitados = Boolean(
      acct.payouts_enabled && acct.capabilities?.transfers === "active",
    );
    const detallesEnviados = Boolean(acct.details_submitted);
    await supabaseAdmin.from("artesanos")
      .update({ cobros_habilitados: cobrosHabilitados, cobros_detalles_enviados: detallesEnviados })
      .eq("id", artesanoId);
    return res.json({ ok: true, conectado: true, cobrosHabilitados, detallesEnviados });
  } catch (e) {
    console.error("[stripe/estado]:", e instanceof Error ? e.message : e);
    return res.status(500).json({ ok: false, error: "No se pudo consultar Stripe." });
  }
});

/**
 * POST /sellers/email — correo de acceso (auth.users) del artesano para el panel ADMIN.
 * El email vive en auth.users (solo service_role lo lee), no en la tabla public.artesanos.
 * service_role + Bearer; artesanoId resuelto en BD (anti-IDOR).
 */
sellersRouter.post("/email", async (req, res) => {
  if (!servicioAutorizado(req)) return res.status(401).json({ ok: false, error: "No autorizado." });
  const artesanoId = typeof req.body?.artesanoId === "string" ? req.body.artesanoId : "";
  if (!artesanoId) return res.status(400).json({ ok: false, error: "Falta artesanoId." });

  const { data: art } = await supabaseAdmin
    .from("artesanos").select("user_id").eq("id", artesanoId).maybeSingle();
  const userId = (art as { user_id: string | null } | null)?.user_id;
  if (!userId) return res.json({ ok: true, email: null });

  try {
    const { data, error } = await supabaseAdmin.auth.admin.getUserById(userId);
    if (error) {
      console.error("[email]:", error.message);
      return res.status(500).json({ ok: false, error: "No se pudo leer el correo." });
    }
    return res.json({ ok: true, email: data.user?.email ?? null });
  } catch (e) {
    console.error("[email]:", e instanceof Error ? e.message : e);
    return res.status(500).json({ ok: false, error: "No se pudo leer el correo." });
  }
});

/**
 * POST /sellers/stripe/detalle — datos NO sensibles de la cuenta Connect para el panel ADMIN.
 * Stripe NUNCA devuelve el RFC/CLABE completos (solo *_provided + last4), así que esto es seguro
 * de mostrar. service_role + Bearer. NO acepta account del cliente (anti-IDOR).
 */
sellersRouter.post("/stripe/detalle", async (req, res) => {
  if (!config.stripeSecretKey) return res.status(503).json({ ok: false, error: "Stripe no configurado." });
  if (!servicioAutorizado(req)) return res.status(401).json({ ok: false, error: "No autorizado." });
  const artesanoId = typeof req.body?.artesanoId === "string" ? req.body.artesanoId : "";
  if (!artesanoId) return res.status(400).json({ ok: false, error: "Falta artesanoId." });

  const { data: art } = await supabaseAdmin
    .from("artesanos").select("stripe_account_id").eq("id", artesanoId).maybeSingle();
  const accountId = (art as { stripe_account_id: string | null } | null)?.stripe_account_id;
  if (!accountId) return res.json({ ok: true, conectado: false });

  try {
    const a = await stripe().accounts.retrieve(accountId);
    const ind = a.individual;
    const comp = a.company;
    const ext = a.external_accounts?.data?.[0] as
      | { bank_name?: string | null; last4?: string | null }
      | undefined;

    const req = a.requirements;
    const pendientes = req?.currently_due ?? [];
    const due = [...pendientes, ...(req?.eventually_due ?? []), ...(req?.past_due ?? [])];
    // Cuentas Express: Stripe NO expone `id_number_provided`. Se INFIERE: si el RFC
    // (individual.id_number / company.tax_id) ya no está pendiente y los datos fueron
    // enviados, es que se registró. (Se combina con el flag explícito por si acaso.)
    const rfcPendiente = due.some((k) => /id_number|tax_id/.test(k));
    const rfcRegistrado =
      Boolean(comp?.tax_id_provided || ind?.id_number_provided) ||
      (Boolean(a.details_submitted) && !rfcPendiente);

    return res.json({
      ok: true,
      conectado: true,
      businessType: a.business_type ?? null,
      nombre: comp?.name ?? [ind?.first_name, ind?.last_name].filter(Boolean).join(" ") ?? null,
      email: a.email ?? null,
      pais: a.country ?? null,
      rfcRegistrado,
      banco: ext ? { nombre: ext.bank_name ?? null, last4: ext.last4 ?? null } : null,
      chargesEnabled: Boolean(a.charges_enabled),
      payoutsEnabled: Boolean(a.payouts_enabled),
      detallesEnviados: Boolean(a.details_submitted),
      // Lista de requisitos pendientes (códigos de Stripe); el web los traduce.
      requisitos: pendientes,
    });
  } catch (e) {
    console.error("[stripe/detalle]:", e instanceof Error ? e.message : e);
    return res.status(500).json({ ok: false, error: "No se pudo consultar Stripe." });
  }
});

/**
 * POST /sellers/stripe/account-session — onboarding EMBEBIDO (cobros). Crea (si falta) la cuenta
 * Connect Express del artesano y devuelve el `client_secret` de una Account Session con el
 * componente `account_onboarding` habilitado, para montar el formulario DENTRO de /vendedor/cobros
 * (con marca, sin redirect a connect.stripe.com). Mismo authz que /stripe/onboarding (Bearer +
 * artesanoId resuelto en BD; anti-IDOR: NUNCA se acepta `account`/`stripe_account_id` del cliente).
 * El `client_secret` es de UN SOLO USO y de vida corta: se genera por request, no se persiste ni
 * se loguea. `external_account_collection` queda en su default (true) → recolecta la CLABE para
 * RECIBIR transferencias (no cobro directo). Sin capability card_payments.
 */
sellersRouter.post("/stripe/account-session", async (req, res) => {
  if (!config.stripeSecretKey) return res.status(503).json({ ok: false, error: "Stripe no configurado." });
  if (!servicioAutorizado(req)) return res.status(401).json({ ok: false, error: "No autorizado." });
  const artesanoId = typeof req.body?.artesanoId === "string" ? req.body.artesanoId : "";
  const email = typeof req.body?.email === "string" ? req.body.email : undefined;
  if (!artesanoId) return res.status(400).json({ ok: false, error: "Falta artesanoId." });

  const { data: art, error } = await supabaseAdmin
    .from("artesanos").select("id,stripe_account_id").eq("id", artesanoId).maybeSingle();
  if (error || !art) return res.status(404).json({ ok: false, error: "Artesano no encontrado." });
  let accountId = (art as { stripe_account_id: string | null }).stripe_account_id;

  try {
    if (!accountId) {
      const account = await stripe().accounts.create({
        type: "express",
        country: "MX",
        email,
        capabilities: { transfers: { requested: true } },
      });
      accountId = account.id;
      await supabaseAdmin.from("artesanos").update({ stripe_account_id: accountId }).eq("id", artesanoId);
    }
    const session = await stripe().accountSessions.create({
      account: accountId,
      components: {
        account_onboarding: { enabled: true },
        // account_management: permite al artesano MODIFICAR sus datos ya conectados
        // (mismo client_secret sirve para ambos componentes embebidos).
        account_management: { enabled: true },
      },
    });
    return res.json({ ok: true, clientSecret: session.client_secret });
  } catch (e) {
    console.error("[stripe/account-session]:", e instanceof Error ? e.message : e);
    return res.status(500).json({ ok: false, error: "No se pudo iniciar la conexión con Stripe." });
  }
});

// Resto del módulo sellers (perfil, etc.): aún pendiente.
sellersRouter.use((_req, res) => res.status(501).json({ module: "sellers", status: "pendiente" }));
