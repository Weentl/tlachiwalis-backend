import { Router } from "express";
import { createHash, timingSafeEqual } from "node:crypto";
import { z } from "zod";
import { supabaseAdmin } from "../../supabase";
import { config } from "../../config";
import { requireBuyer, type BuyerReq } from "./require-buyer";

export const buyersRouter = Router();

// Comparación de secreto en tiempo constante (sha256 → longitud fija).
function secretoIgual(a: string, b: string): boolean {
  const ha = createHash("sha256").update(a).digest();
  const hb = createHash("sha256").update(b).digest();
  return ha.length === hb.length && timingSafeEqual(ha, hb);
}

const registroSchema = z.object({
  email: z.string().email().transform((s) => s.trim().toLowerCase()),
  password: z.string().min(8).max(72), // 72 = límite bcrypt de GoTrue
  // Registro MÍNIMO: nombre opcional (perfilado progresivo); sin teléfono (se pide en el checkout).
  nombre: z.string().trim().max(120).optional().default(""),
  telefono: z.string().trim().optional().default(""),
  // Consentimiento de marketing (LFPDPPP): separado, no premarcado. Evidencia en perfiles (0024).
  marketing_consent: z.boolean().optional().default(false),
});

/**
 * POST /buyers/register — alta de COMPRADOR. Como GOTRUE_DISABLE_SIGNUP puede estar en true
 * (signup público cerrado), creamos la cuenta con service_role (mismo patrón que /sellers), SIN
 * invitación. Authz por Bearer del secreto compartido (CLAIM_SERVICE_TOKEN). El trigger
 * handle_new_user (0023) crea el perfil tomando el nombre de user_metadata. La validación de
 * FORTALEZA de la contraseña la hace el frontend (passwordFuerteSchema); aquí solo largo/formato.
 */
buyersRouter.post("/register", async (req, res) => {
  const authz = req.header("authorization") ?? "";
  const provided = authz.startsWith("Bearer ") ? authz.slice(7) : "";
  if (!provided || !config.claimServiceToken || !secretoIgual(provided, config.claimServiceToken)) {
    return res.status(401).json({ ok: false, error: "No autorizado." });
  }

  const parsed = registroSchema.safeParse(req.body);
  if (!parsed.success) {
    return res
      .status(200)
      .json({ ok: false, error: `Datos inválidos: ${parsed.error.issues[0]?.message ?? ""}` });
  }
  const d = parsed.data;

  const { data, error } = await supabaseAdmin.auth.admin.createUser({
    email: d.email,
    password: d.password,
    email_confirm: true, // sin SMTP: se marca verificado (igual que artesanos)
    user_metadata: {
      nombre: d.nombre || undefined,
      telefono: d.telefono || undefined,
      marketing_consent: d.marketing_consent, // el trigger handle_new_user (0024) lo persiste
    },
  });
  if (error || !data.user) {
    const enUso = /already|registered|exists|duplicate/i.test(error?.message ?? "");
    if (enUso) {
      return res
        .status(200)
        .json({ ok: false, error: "Ese correo ya tiene una cuenta.", code: "email_en_uso" });
    }
    console.error("[buyers/register]:", error?.message);
    return res.status(500).json({ ok: false, error: "No se pudo crear la cuenta." });
  }

  return res.json({ ok: true, userId: data.user.id });
});

/**
 * POST /buyers/delete-account — ARCO (Cancelación): el COMPRADOR elimina SU cuenta.
 * Authz por su propio JWT (requireBuyer). Borra el usuario en GoTrue → cascada a perfiles/
 * direcciones (FK on delete cascade, 0023). GUARDA: si la cuenta está ligada a un TALLER
 * (artesanos) o es ADMIN, NO se borra aquí (tiene datos de negocio/fiscales) — se atiende aparte.
 */
buyersRouter.post("/delete-account", requireBuyer, async (req: BuyerReq, res) => {
  const uid = req.buyer!.id;

  const [{ data: art }, { data: adm }] = await Promise.all([
    supabaseAdmin.from("artesanos").select("id").eq("user_id", uid).maybeSingle(),
    supabaseAdmin.from("admins").select("user_id").eq("user_id", uid).maybeSingle(),
  ]);
  if (art || adm) {
    return res.status(409).json({
      ok: false,
      code: "cuenta_ligada",
      error: "Tu cuenta está ligada a un taller o al equipo. Escríbenos para darla de baja.",
    });
  }

  const { error } = await supabaseAdmin.auth.admin.deleteUser(uid);
  if (error) {
    console.error("[buyers/delete-account]:", error.message);
    return res.status(500).json({ ok: false, error: "No se pudo eliminar la cuenta." });
  }
  return res.json({ ok: true });
});
