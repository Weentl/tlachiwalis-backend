import dotenv from "dotenv";

// Carga .env.local primero, luego .env
dotenv.config({ path: ".env.local" });
dotenv.config();

export const config = {
  port: Number(process.env.PORT ?? 4000),
  webOrigin: process.env.WEB_ORIGIN ?? "http://localhost:3000",
  supabaseUrl: process.env.SUPABASE_URL ?? "",
  supabaseSecretKey: process.env.SUPABASE_SECRET_KEY ?? "",
  // Secreto de servicio compartido con el web app para autorizar el claim de
  // invitación (POST /sellers/claim). Fail-closed: si está vacío, el alta se apaga.
  claimServiceToken: process.env.CLAIM_SERVICE_TOKEN ?? "",
  // Stripe Connect (modo PRUEBA por ahora). El secret vive SOLO aquí (backend).
  // La lógica de cobros/dispersión/retenciones va bajo el gate del CLAUDE.md.
  stripeSecretKey: process.env.STRIPE_SECRET_KEY ?? "",
  stripeWebhookSecret: process.env.STRIPE_WEBHOOK_SECRET ?? "",
};

export const stripeConfigured = Boolean(process.env.STRIPE_SECRET_KEY);

export const supabaseConfigured = Boolean(config.supabaseUrl && config.supabaseSecretKey);
