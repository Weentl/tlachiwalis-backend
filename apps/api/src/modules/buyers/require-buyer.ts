import type { Request, Response, NextFunction } from "express";
import { supabaseAdmin } from "../../supabase";

/**
 * requireBuyer — autentica al COMPRADOR por su JWT de Supabase (Bearer access_token).
 * Distinto del CLAIM_SERVICE_TOKEN (secreto de servicio para /buyers/register). Verifica el
 * token contra GoTrue vía service_role (auth.getUser) y adjunta el usuario a req.buyer.
 * Se reutiliza en pagos (F6). El backend hace su propia authz por usuario (anti-IDOR).
 */
export type BuyerReq = Request & { buyer?: { id: string; email: string | null } };

export async function requireBuyer(req: BuyerReq, res: Response, next: NextFunction) {
  const authz = req.header("authorization") ?? "";
  const token = authz.startsWith("Bearer ") ? authz.slice(7) : "";
  if (!token) return res.status(401).json({ ok: false, error: "No autorizado." });

  try {
    const { data, error } = await supabaseAdmin.auth.getUser(token);
    if (error || !data.user) {
      return res.status(401).json({ ok: false, error: "Sesión inválida." });
    }
    req.buyer = { id: data.user.id, email: data.user.email ?? null };
    next();
  } catch {
    return res.status(401).json({ ok: false, error: "No se pudo validar la sesión." });
  }
}
