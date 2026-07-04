import Stripe from "stripe";
import { config } from "./config";

/**
 * Cliente de Stripe (modo PRUEBA por ahora). El secret vive SOLO en el backend.
 * Creación perezosa: no truena al importar si falta la key; falla al usarse.
 */
let cliente: Stripe | null = null;

export function stripe(): Stripe {
  if (!config.stripeSecretKey) {
    throw new Error("STRIPE_SECRET_KEY no configurado en apps/api/.env.local");
  }
  if (!cliente) cliente = new Stripe(config.stripeSecretKey);
  return cliente;
}
