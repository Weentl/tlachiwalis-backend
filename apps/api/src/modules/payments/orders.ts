import { stripe } from "../../stripe";
import { supabaseAdmin } from "../../supabase";

// Comisión de plataforma (se descuenta del artesano; el comprador paga el precio de lista).
export const COMISION_BPS = 1000; // 10%

export type ItemEntrada = { productoId: string; varianteId: string; cantidad: number };
export type LineaOrden = {
  productoId: string;
  varianteId: string;
  artesanoId: string | null;
  nombre: string;
  opciones: Record<string, unknown>;
  cantidad: number;
  precioCentavos: number; // unitario
  subtotalCentavos: number;
  pesoGramos: number | null; // para cotizar el envío
};

/**
 * Recalcula el carrito DESDE LA BD (servidor = autoridad de precios; nunca se confía en montos del
 * cliente). Valida: variante activa, producto publicado, stock suficiente. Devuelve las líneas con
 * el precio efectivo (base + delta) y el artesano de cada una, o un error legible.
 */
export async function recalcularItems(
  items: ItemEntrada[],
): Promise<{ lineas: LineaOrden[]; total: number } | { error: string }> {
  if (!Array.isArray(items) || items.length === 0) return { error: "Carrito vacío." };
  const lineas: LineaOrden[] = [];

  for (const it of items) {
    const qty = Math.floor(it.cantidad);
    if (!it.varianteId || !it.productoId || qty <= 0) return { error: "Ítem inválido." };

    const { data: v } = await supabaseAdmin
      .from("producto_variantes")
      .select(
        "id,producto_id,opciones,precio_delta_centavos,activa,productos(precio_centavos,nombre,artesano_id,status,peso_gramos,artesanos(stripe_account_id,cobros_habilitados,status)),inventario(disponible)",
      )
      .eq("id", it.varianteId)
      .maybeSingle();

    const prod = (v as { productos?: unknown } | null)?.productos as
      | {
          precio_centavos?: number;
          nombre?: string;
          artesano_id?: string | null;
          status?: string;
          peso_gramos?: number | null;
          artesanos?:
            | { stripe_account_id?: string | null; cobros_habilitados?: boolean; status?: string }
            | { stripe_account_id?: string | null; cobros_habilitados?: boolean; status?: string }[]
            | null;
        }
      | undefined;
    const invRaw = (v as { inventario?: unknown } | null)?.inventario;
    const inv = Array.isArray(invRaw) ? invRaw[0] : invRaw;
    const disponible = (inv as { disponible?: number } | null)?.disponible ?? 0;
    const artRaw = prod?.artesanos;
    const art = Array.isArray(artRaw) ? artRaw[0] : artRaw;

    if (!v || !prod) return { error: "Una pieza ya no está disponible." };
    if (!v.activa || prod.status !== "publicado") return { error: `"${prod.nombre}" ya no está a la venta.` };
    if (v.producto_id !== it.productoId) return { error: "Ítem inconsistente." };
    if (disponible < qty) return { error: `"${prod.nombre}" no tiene suficiente inventario.` };
    // SEGURIDAD: nunca cobrar una pieza sin ruta de dispersión (artesano sin cuenta Stripe activa,
    // o taller pausado). Las piezas de exhibición (es_demo) caen aquí: browsables pero NO comprables.
    if (!art?.stripe_account_id || !art?.cobros_habilitados || art?.status !== "activo") {
      return { error: `"${prod.nombre}" es una pieza de exhibición y no está disponible para compra.` };
    }

    const precio = (prod.precio_centavos ?? 0) + ((v.precio_delta_centavos as number) ?? 0);
    lineas.push({
      productoId: it.productoId,
      varianteId: it.varianteId,
      artesanoId: prod.artesano_id ?? null,
      nombre: prod.nombre ?? "Pieza",
      opciones: (v.opciones as Record<string, unknown>) ?? {},
      cantidad: qty,
      precioCentavos: precio,
      subtotalCentavos: precio * qty,
      pesoGramos: prod.peso_gramos ?? null,
    });
  }

  const total = lineas.reduce((s, l) => s + l.subtotalCentavos, 0);
  return { lineas, total };
}

/**
 * Finaliza una orden pagada (IDEMPOTENTE): marca pagada, decrementa inventario y TRANSFIERE a cada
 * artesano su neto (subtotal − comisión) vía Connect (separate charges & transfers, source_transaction
 * = el cargo). Lo llaman el webhook (autoridad) y el confirm del cliente (testeable en local). Doble
 * ejecución es segura: status de la orden + UNIQUE(order,artesano) en payouts.
 */
export async function finalizarOrden(paymentIntentId: string): Promise<{ ok: boolean; orderId?: string }> {
  const pi = await stripe().paymentIntents.retrieve(paymentIntentId);
  if (pi.status !== "succeeded") return { ok: false };

  const { data: order } = await supabaseAdmin
    .from("orders")
    .select("id,status,total_centavos")
    .eq("stripe_payment_intent_id", paymentIntentId)
    .maybeSingle();
  if (!order) return { ok: false };
  if (order.status === "pagada") return { ok: true, orderId: order.id as string }; // ya procesada

  await supabaseAdmin
    .from("orders")
    .update({ status: "pagada", updated_at: new Date().toISOString() })
    .eq("id", order.id);

  const { data: items } = await supabaseAdmin
    .from("order_items")
    .select("variante_id,artesano_id,cantidad,subtotal_centavos")
    .eq("order_id", order.id);
  const lineas = (items ?? []) as {
    variante_id: string;
    artesano_id: string | null;
    cantidad: number;
    subtotal_centavos: number;
  }[];

  // Decremento atómico de inventario (anti-sobreventa).
  for (const l of lineas) {
    if (l.variante_id) {
      const { data: ok } = await supabaseAdmin.rpc("decrementar_stock", {
        p_variante: l.variante_id,
        p_qty: l.cantidad,
      });
      if (ok === false) console.warn(`[orden ${order.id}] sin stock para variante ${l.variante_id}`);
    }
  }

  // Agrupa por artesano → un payout (transfer) por artesano.
  const porArtesano = new Map<string, number>();
  for (const l of lineas) {
    if (!l.artesano_id) continue;
    porArtesano.set(l.artesano_id, (porArtesano.get(l.artesano_id) ?? 0) + l.subtotal_centavos);
  }
  const charge = typeof pi.latest_charge === "string" ? pi.latest_charge : pi.latest_charge?.id;

  for (const [artesanoId, bruto] of porArtesano) {
    const comision = Math.round((bruto * COMISION_BPS) / 10000);
    const neto = bruto - comision;

    // ¿el artesano ya tiene payout de esta orden? (idempotencia app + UNIQUE)
    const { data: existe } = await supabaseAdmin
      .from("payouts")
      .select("id")
      .eq("order_id", order.id)
      .eq("artesano_id", artesanoId)
      .maybeSingle();
    if (existe) continue;

    const { data: art } = await supabaseAdmin
      .from("artesanos")
      .select("stripe_account_id,cobros_habilitados")
      .eq("id", artesanoId)
      .maybeSingle();
    const cuenta = (art as { stripe_account_id?: string | null } | null)?.stripe_account_id ?? null;

    let status = "sin_cuenta";
    let transferId: string | null = null;
    if (cuenta && neto > 0 && charge) {
      try {
        const tr = await stripe().transfers.create(
          {
            amount: neto,
            currency: "mxn",
            destination: cuenta,
            source_transaction: charge,
            transfer_group: order.id as string,
            metadata: { order_id: order.id as string, artesano_id: artesanoId },
          },
          { idempotencyKey: `payout_${order.id}_${artesanoId}` },
        );
        status = "transferido";
        transferId = tr.id;
      } catch (e) {
        status = "fallido";
        console.error(`[orden ${order.id}] transfer a ${artesanoId} falló:`, e instanceof Error ? e.message : e);
      }
    }

    await supabaseAdmin.from("payouts").insert({
      order_id: order.id,
      artesano_id: artesanoId,
      bruto_centavos: bruto,
      comision_centavos: comision,
      neto_centavos: neto,
      stripe_transfer_id: transferId,
      status,
    });
  }

  return { ok: true, orderId: order.id as string };
}
