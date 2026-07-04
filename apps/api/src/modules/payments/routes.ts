import { Router } from "express";
import type Stripe from "stripe";
import { z } from "zod";
import { stripe } from "../../stripe";
import { supabaseAdmin } from "../../supabase";
import { requireBuyer, type BuyerReq } from "../buyers/require-buyer";

export const paymentsRouter = Router();

// El Customer vive en la cuenta PLATAFORMA. Se guarda en perfiles.stripe_customer_id (0025).
async function getCustomerId(userId: string): Promise<string | null> {
  const { data } = await supabaseAdmin
    .from("perfiles")
    .select("stripe_customer_id")
    .eq("user_id", userId)
    .maybeSingle();
  return (data as { stripe_customer_id?: string | null } | null)?.stripe_customer_id ?? null;
}

// Recupera o crea (perezosamente) el Customer del comprador.
async function getOrCreateCustomer(userId: string, email: string | null): Promise<string> {
  const existing = await getCustomerId(userId);
  if (existing) return existing;
  const customer = await stripe().customers.create({
    email: email ?? undefined,
    metadata: { supabase_user_id: userId },
  });
  const { error } = await supabaseAdmin
    .from("perfiles")
    .update({ stripe_customer_id: customer.id })
    .eq("user_id", userId);
  if (error) console.error("[payments] guardar stripe_customer_id:", error.message);
  return customer.id;
}

const idSchema = z.object({ id: z.string().trim().min(1).max(120) });

function defaultPmId(customer: Stripe.Customer | Stripe.DeletedCustomer): string | null {
  const c = customer as Stripe.Customer;
  const d = c.invoice_settings?.default_payment_method;
  return typeof d === "string" ? d : (d?.id ?? null);
}

/**
 * POST /payments/setup-intent — inicia el guardado de una tarjeta (Payment Element).
 * Crea/recupera el Customer y devuelve el client_secret del SetupIntent (usage off_session).
 * El número de tarjeta NUNCA pasa por aquí (lo captura Stripe Elements en el cliente).
 */
paymentsRouter.post("/setup-intent", requireBuyer, async (req: BuyerReq, res) => {
  try {
    const customer = await getOrCreateCustomer(req.buyer!.id, req.buyer!.email);
    const si = await stripe().setupIntents.create(
      { customer, payment_method_types: ["card"], usage: "off_session" },
      { idempotencyKey: `si_${req.buyer!.id}_${Date.now()}` },
    );
    return res.json({ ok: true, clientSecret: si.client_secret });
  } catch (e) {
    console.error("[payments/setup-intent]:", e instanceof Error ? e.message : e);
    return res.status(500).json({ ok: false, error: "No se pudo iniciar el guardado." });
  }
});

/** GET /payments/payment-methods — tarjetas guardadas (proyección segura, sin PAN). */
paymentsRouter.get("/payment-methods", requireBuyer, async (req: BuyerReq, res) => {
  try {
    const customerId = await getCustomerId(req.buyer!.id);
    if (!customerId) return res.json({ ok: true, metodos: [] });
    const [pms, customer] = await Promise.all([
      stripe().paymentMethods.list({ customer: customerId, type: "card" }),
      stripe().customers.retrieve(customerId),
    ]);
    const def = defaultPmId(customer);
    const metodos = pms.data.map((pm) => ({
      id: pm.id,
      brand: pm.card?.brand ?? "card",
      last4: pm.card?.last4 ?? "",
      expMonth: pm.card?.exp_month ?? 0,
      expYear: pm.card?.exp_year ?? 0,
      isDefault: pm.id === def,
    }));
    return res.json({ ok: true, metodos });
  } catch (e) {
    console.error("[payments/payment-methods]:", e instanceof Error ? e.message : e);
    return res.status(500).json({ ok: false, error: "No se pudieron cargar tus tarjetas." });
  }
});

/** POST /payments/payment-methods/detach — quita una tarjeta (anti-IDOR: verifica dueño). */
paymentsRouter.post("/payment-methods/detach", requireBuyer, async (req: BuyerReq, res) => {
  const parsed = idSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ ok: false, error: "Falta el id." });
  try {
    const customerId = await getCustomerId(req.buyer!.id);
    if (!customerId) return res.status(404).json({ ok: false, error: "Sin métodos." });
    const pm = await stripe().paymentMethods.retrieve(parsed.data.id);
    if (pm.customer !== customerId) return res.status(403).json({ ok: false, error: "No autorizado." });
    await stripe().paymentMethods.detach(parsed.data.id);
    return res.json({ ok: true });
  } catch (e) {
    console.error("[payments/detach]:", e instanceof Error ? e.message : e);
    return res.status(500).json({ ok: false, error: "No se pudo quitar la tarjeta." });
  }
});

/** POST /payments/payment-methods/default — marca predeterminada (anti-IDOR). */
paymentsRouter.post("/payment-methods/default", requireBuyer, async (req: BuyerReq, res) => {
  const parsed = idSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ ok: false, error: "Falta el id." });
  try {
    const customerId = await getCustomerId(req.buyer!.id);
    if (!customerId) return res.status(404).json({ ok: false, error: "Sin métodos." });
    const pm = await stripe().paymentMethods.retrieve(parsed.data.id);
    if (pm.customer !== customerId) return res.status(403).json({ ok: false, error: "No autorizado." });
    await stripe().customers.update(customerId, {
      invoice_settings: { default_payment_method: parsed.data.id },
    });
    return res.json({ ok: true });
  } catch (e) {
    console.error("[payments/default]:", e instanceof Error ? e.message : e);
    return res.status(500).json({ ok: false, error: "No se pudo actualizar." });
  }
});
