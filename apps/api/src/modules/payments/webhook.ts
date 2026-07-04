import express from "express";
import type Stripe from "stripe";
import { stripe } from "../../stripe";
import { config } from "../../config";
import { supabaseAdmin } from "../../supabase";
import { finalizarOrden } from "./orders";

export const webhooksRouter = express.Router();

/**
 * POST /webhooks/stripe — receptor de eventos de Stripe. Reglas del CLAUDE.md:
 *  - Verificar la FIRMA con STRIPE_WEBHOOK_SECRET (rechazar inválidos).
 *  - IDEMPOTENCIA: insertar-o-saltar en processed_webhook_events (PK event_id).
 *  - Responder 200 RÁPIDO (Stripe reintenta si no).
 * Usa RAW body (express.raw) porque la verificación de firma necesita el cuerpo sin parsear;
 * por eso este router se monta ANTES de express.json en index.ts.
 */
webhooksRouter.post(
  "/stripe",
  express.raw({ type: "application/json" }),
  async (req, res) => {
    if (!config.stripeSecretKey || !config.stripeWebhookSecret) {
      return res.status(503).send("Stripe no configurado.");
    }
    const sig = req.header("stripe-signature") ?? "";

    let event: import("stripe").Stripe.Event;
    try {
      event = stripe().webhooks.constructEvent(req.body, sig, config.stripeWebhookSecret);
    } catch (e) {
      console.error("[webhook] firma inválida:", e instanceof Error ? e.message : e);
      return res.status(400).send("Firma inválida.");
    }

    // Idempotencia: PK(event_id). Violación de unicidad = ya procesado → 200.
    const { error: dupErr } = await supabaseAdmin
      .from("processed_webhook_events")
      .insert({ event_id: event.id, tipo: event.type });
    if (dupErr) {
      if (!/duplicate|unique|already exists/i.test(dupErr.message)) {
        console.error("[webhook] insert idempotencia:", dupErr.message);
      }
      return res.status(200).json({ received: true, duplicate: true });
    }

    try {
      switch (event.type) {
        case "account.updated": {
          const acct = event.data.object as {
            id: string;
            charges_enabled?: boolean;
            payouts_enabled?: boolean;
            details_submitted?: boolean;
            capabilities?: { transfers?: string };
          };
          // FASE 3 (cobros): reflejar el estado de la cuenta Connect en `artesanos`. Modelo
          // separate charges & transfers → la cuenta solo RECIBE transferencias, `charges_enabled`
          // nunca se prende. La señal de "puede recibir su dinero" (→ habilita PUBLICAR) es
          // payouts_enabled + capability transfers 'active'.
          const cobros = Boolean(
            acct.payouts_enabled && acct.capabilities?.transfers === "active",
          );
          const { error: updErr } = await supabaseAdmin
            .from("artesanos")
            .update({
              cobros_habilitados: cobros,
              cobros_detalles_enviados: Boolean(acct.details_submitted),
            })
            .eq("stripe_account_id", acct.id);
          if (updErr) console.error("[webhook] account.updated update:", updErr.message);
          else console.log(`[webhook] account.updated ${acct.id} cobros=${cobros}`);
          break;
        }
        case "payment_intent.succeeded": {
          // Pago de checkout confirmado → finalizar la orden (marcar pagada, decrementar inventario,
          // transferir a cada artesano). Idempotente (el confirm del cliente hace lo mismo).
          const pi = event.data.object as Stripe.PaymentIntent;
          if (pi.metadata?.order_id) await finalizarOrden(pi.id);
          break;
        }
        case "setup_intent.succeeded": {
          // Tarjeta guardada. Si el comprador no tiene predeterminada aún, dejar esta como default.
          const si = event.data.object as Stripe.SetupIntent;
          const customer = typeof si.customer === "string" ? si.customer : si.customer?.id;
          const pm = typeof si.payment_method === "string" ? si.payment_method : si.payment_method?.id;
          if (customer && pm) {
            const c = await stripe().customers.retrieve(customer);
            const d = (c as Stripe.Customer).invoice_settings?.default_payment_method;
            const hasDefault = typeof d === "string" ? d : d?.id;
            if (!hasDefault) {
              await stripe().customers.update(customer, {
                invoice_settings: { default_payment_method: pm },
              });
              console.log(`[webhook] setup_intent.succeeded → default pm ${pm} para ${customer}`);
            }
          }
          break;
        }
        default:
          console.log(`[webhook] evento sin manejar: ${event.type}`);
      }
    } catch (e) {
      // No fallar el 200 por un error del handler (evita reintentos infinitos); se registra.
      console.error("[webhook] handler:", e instanceof Error ? e.message : e);
    }

    return res.status(200).json({ received: true });
  },
);
