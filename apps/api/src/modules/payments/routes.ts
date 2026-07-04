import { Router } from "express";
import { randomUUID } from "node:crypto";
import type Stripe from "stripe";
import { z } from "zod";
import { stripe } from "../../stripe";
import { supabaseAdmin } from "../../supabase";
import { requireBuyer, type BuyerReq } from "../buyers/require-buyer";
import { recalcularItems, finalizarOrden, COMISION_BPS } from "./orders";
import { cotizarEnvio } from "../shipping/quote";

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

// ── Checkout ──────────────────────────────────────────────────────────────
const facturacionSchema = z.object({
  rfc: z
    .string()
    .trim()
    .toUpperCase()
    .regex(/^[A-ZÑ&0-9]{12,13}$/, "RFC inválido"),
  razonSocial: z.string().trim().max(200).optional(),
  regimenFiscal: z.string().trim().max(10).optional(),
  usoCfdi: z.string().trim().max(10).optional(),
  cpFiscal: z.string().trim().max(10).optional(),
  email: z.string().trim().email().max(160).optional(),
});

const checkoutSchema = z.object({
  items: z
    .array(
      z.object({
        productoId: z.string().min(1).max(120),
        varianteId: z.string().min(1).max(120),
        cantidad: z.number().int().positive().max(99),
      }),
    )
    .min(1)
    .max(50),
  idempotencyKey: z.string().min(8).max(120).optional(),
  // Dirección de envío: id de una direccion del comprador (se valida propiedad → snapshot).
  direccionId: z.string().uuid().optional(),
  // Solicitud de factura (opcional). Presente ⇒ requiere_factura. CFDI se emite después (módulo tax).
  facturacion: facturacionSchema.optional(),
  // Guardar la tarjeta usada para próximas compras (setup_future_usage off_session).
  guardarTarjeta: z.boolean().optional(),
});

/**
 * POST /payments/checkout — crea la orden (servidor recalcula precios desde la BD, NUNCA confía en el
 * cliente) y un PaymentIntent (solo tarjeta, sin Link) por el total. Devuelve client_secret + orderId.
 */
paymentsRouter.post("/checkout", requireBuyer, async (req: BuyerReq, res) => {
  const parsed = checkoutSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ ok: false, error: "Datos de checkout inválidos." });

  const calc = await recalcularItems(parsed.data.items);
  if ("error" in calc) return res.status(400).json({ ok: false, error: calc.error });
  const { lineas, total } = calc;
  if (total <= 0) return res.status(400).json({ ok: false, error: "Total inválido." });

  // Comisión total = suma de comisiones por artesano.
  const brutoPorArtesano = new Map<string, number>();
  for (const l of lineas)
    if (l.artesanoId) brutoPorArtesano.set(l.artesanoId, (brutoPorArtesano.get(l.artesanoId) ?? 0) + l.subtotalCentavos);
  let comisionTotal = 0;
  for (const bruto of brutoPorArtesano.values()) comisionTotal += Math.round((bruto * COMISION_BPS) / 10000);

  // Idempotencia: si ya existe una orden con este client_key (doble submit), devolverla en vez de
  // crear otra + otro PaymentIntent.
  if (parsed.data.idempotencyKey) {
    const { data: existente } = await supabaseAdmin
      .from("orders")
      .select("id,stripe_payment_intent_id,total_centavos")
      .eq("client_key", parsed.data.idempotencyKey)
      .eq("comprador_id", req.buyer!.id)
      .maybeSingle();
    const prev = existente as { id?: string; stripe_payment_intent_id?: string; total_centavos?: number } | null;
    if (prev?.stripe_payment_intent_id) {
      try {
        const pi = await stripe().paymentIntents.retrieve(prev.stripe_payment_intent_id);
        return res.json({ ok: true, orderId: prev.id, clientSecret: pi.client_secret, total: prev.total_centavos });
      } catch {
        /* si el PI ya no existe, cae a crear una nueva orden abajo */
      }
    }
  }

  const orderId = `ord_${randomUUID()}`;
  try {
    const customer = await getOrCreateCustomer(req.buyer!.id, req.buyer!.email);

    // Snapshot de ENVÍO: valida que la dirección sea del comprador (anti-IDOR) y la congela en la
    // orden. Si luego edita/borra la dirección, la orden conserva a dónde se envió.
    let direccionSnap: Record<string, unknown> | null = null;
    if (parsed.data.direccionId) {
      const { data: dir } = await supabaseAdmin
        .from("direcciones")
        .select("user_id,destinatario,telefono,calle,colonia,ciudad,estado,cp,referencias")
        .eq("id", parsed.data.direccionId)
        .maybeSingle();
      const d = dir as ({ user_id?: string } & Record<string, unknown>) | null;
      if (!d || d.user_id !== req.buyer!.id) {
        return res.status(403).json({ ok: false, error: "Dirección no válida." });
      }
      direccionSnap = {
        destinatario: d.destinatario ?? null,
        telefono: d.telefono ?? null,
        calle: d.calle ?? null,
        colonia: d.colonia ?? null,
        ciudad: d.ciudad ?? null,
        estado: d.estado ?? null,
        cp: d.cp ?? null,
        referencias: d.referencias ?? null,
      };
    }

    // Snapshot de FACTURACIÓN (opcional). CFDI se emite después (módulo tax); aquí solo se captura.
    const fact = parsed.data.facturacion;
    const facturacionSnap = fact
      ? {
          rfc: fact.rfc,
          razon_social: fact.razonSocial ?? null,
          regimen_fiscal: fact.regimenFiscal ?? null,
          uso_cfdi: fact.usoCfdi ?? null,
          cp_fiscal: fact.cpFiscal ?? null,
          email: fact.email ?? null,
        }
      : null;

    // ENVÍO: AUTORIDAD del servidor. Se cotiza desde el CP de la dirección elegida + peso de los
    // ítems (nunca se confía en un monto del cliente). El envío se queda en la plataforma (no se
    // dispersa al artesano; los payouts siguen basados en subtotales de ítems).
    const cpDestino = (direccionSnap?.cp as string | null | undefined) ?? null;
    const cot = await cotizarEnvio(
      cpDestino,
      lineas.map((l) => ({ pesoGramos: l.pesoGramos, cantidad: l.cantidad })),
      total,
    );
    const envioCentavos = cot.costoCentavos;
    const totalConEnvio = total + envioCentavos;

    const { error: oErr } = await supabaseAdmin.from("orders").insert({
      id: orderId,
      comprador_id: req.buyer!.id,
      email: req.buyer!.email,
      subtotal_centavos: total,
      comision_centavos: comisionTotal,
      total_centavos: totalConEnvio,
      envio_centavos: envioCentavos,
      status: "pendiente",
      client_key: parsed.data.idempotencyKey ?? null,
      direccion_envio: direccionSnap,
      facturacion: facturacionSnap,
      requiere_factura: Boolean(facturacionSnap),
    });
    if (oErr) throw new Error(oErr.message);

    const { error: iErr } = await supabaseAdmin.from("order_items").insert(
      lineas.map((l) => ({
        order_id: orderId,
        producto_id: l.productoId,
        variante_id: l.varianteId,
        artesano_id: l.artesanoId,
        nombre: l.nombre,
        opciones: l.opciones,
        cantidad: l.cantidad,
        precio_centavos: l.precioCentavos,
        subtotal_centavos: l.subtotalCentavos,
      })),
    );
    if (iErr) throw new Error(iErr.message);

    const pi = await stripe().paymentIntents.create(
      {
        amount: totalConEnvio,
        currency: "mxn",
        customer,
        payment_method_types: ["card"],
        transfer_group: orderId,
        // Si el comprador pidió guardar la tarjeta, Stripe la adjunta al Customer al pagar.
        ...(parsed.data.guardarTarjeta ? { setup_future_usage: "off_session" as const } : {}),
        metadata: { order_id: orderId, comprador_id: req.buyer!.id },
      },
      parsed.data.idempotencyKey ? { idempotencyKey: parsed.data.idempotencyKey } : undefined,
    );

    await supabaseAdmin.from("orders").update({ stripe_payment_intent_id: pi.id }).eq("id", orderId);
    return res.json({ ok: true, orderId, clientSecret: pi.client_secret, total: totalConEnvio, envio: envioCentavos });
  } catch (e) {
    console.error("[payments/checkout]:", e instanceof Error ? e.message : e);
    return res.status(500).json({ ok: false, error: "No se pudo iniciar el pago." });
  }
});

/**
 * POST /payments/order/confirm — el cliente lo llama tras confirmar el pago (testeable en local sin
 * webhook). Verifica que la orden sea del comprador y finaliza (idempotente; el webhook hace lo mismo).
 */
paymentsRouter.post("/order/confirm", requireBuyer, async (req: BuyerReq, res) => {
  const piId = String((req.body as { paymentIntentId?: string })?.paymentIntentId ?? "");
  if (!piId) return res.status(400).json({ ok: false, error: "Falta paymentIntentId." });
  const { data: ord } = await supabaseAdmin
    .from("orders")
    .select("comprador_id")
    .eq("stripe_payment_intent_id", piId)
    .maybeSingle();
  if (!ord || ord.comprador_id !== req.buyer!.id) {
    return res.status(403).json({ ok: false, error: "No autorizado." });
  }
  try {
    const r = await finalizarOrden(piId);
    return res.json({ ok: r.ok, orderId: r.orderId });
  } catch (e) {
    console.error("[payments/order/confirm]:", e instanceof Error ? e.message : e);
    return res.status(500).json({ ok: false, error: "No se pudo confirmar la orden." });
  }
});
