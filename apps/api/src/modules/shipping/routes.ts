import { Router } from "express";
import { z } from "zod";
import { supabaseAdmin } from "../../supabase";
import { requireBuyer, type BuyerReq } from "../buyers/require-buyer";
import { cotizarEnvio, pesosDeProductos } from "./quote";

export const shippingRouter = Router();

const quoteSchema = z.object({
  // CP directo, o una dirección del comprador de la que se toma el CP (anti-IDOR: se valida dueño).
  cp: z.string().trim().max(10).optional(),
  direccionId: z.string().uuid().optional(),
  items: z
    .array(
      z.object({
        productoId: z.string().min(1).max(120),
        cantidad: z.number().int().positive().max(99),
      }),
    )
    .min(1)
    .max(50),
  subtotalCentavos: z.number().int().nonnegative().max(100_000_000).optional(),
});

/**
 * POST /shipping/quote — cotiza el envío (zona por CP + peso). Sirve para MOSTRAR el estimado en el
 * checkout; el cobro real lo recalcula /payments/checkout desde el CP de la dirección elegida (misma
 * lógica), así que un cliente no puede alterar el monto.
 */
shippingRouter.post("/quote", requireBuyer, async (req: BuyerReq, res) => {
  const parsed = quoteSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ ok: false, error: "Datos de cotización inválidos." });

  let cp = parsed.data.cp ?? null;
  if (parsed.data.direccionId) {
    const { data: dir } = await supabaseAdmin
      .from("direcciones")
      .select("user_id,cp")
      .eq("id", parsed.data.direccionId)
      .maybeSingle();
    const d = dir as { user_id?: string; cp?: string | null } | null;
    if (!d || d.user_id !== req.buyer!.id) {
      return res.status(403).json({ ok: false, error: "Dirección no válida." });
    }
    cp = d.cp ?? null;
  }

  try {
    const itemsPeso = await pesosDeProductos(parsed.data.items);
    const cot = await cotizarEnvio(cp, itemsPeso, parsed.data.subtotalCentavos ?? 0);
    return res.json({ ok: true, cotizacion: cot });
  } catch (e) {
    console.error("[shipping/quote]:", e instanceof Error ? e.message : e);
    return res.status(500).json({ ok: false, error: "No se pudo cotizar el envío." });
  }
});
