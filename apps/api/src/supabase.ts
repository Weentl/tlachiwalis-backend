import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { config } from "./config";

/**
 * Cliente ADMIN de Supabase: usa la SECRET key y BYPASSA RLS. Vive SOLO en el
 * backend; el frontend nunca tiene esta llave. El backend hace su propia authz
 * antes de usarlo (anti-IDOR).
 *
 * Creación PEREZOSA: NO se crea al importar. Así, si falta SUPABASE_URL/SECRET_KEY,
 * el proceso arranca igual (p.ej. /health y módulos que no tocan Supabase siguen
 * vivos) y solo falla —de forma clara— cuando de verdad se intenta usar la BD.
 */
let cliente: SupabaseClient | null = null;

export function supabaseAdminClient(): SupabaseClient {
  if (!config.supabaseUrl || !config.supabaseSecretKey) {
    throw new Error(
      "Supabase no configurado: define SUPABASE_URL y SUPABASE_SECRET_KEY en apps/api/.env.local",
    );
  }
  if (!cliente) {
    cliente = createClient(config.supabaseUrl, config.supabaseSecretKey, {
      auth: { persistSession: false },
    });
  }
  return cliente;
}

/**
 * Compat: proxy perezoso para el uso existente `supabaseAdmin.from(...)`,
 * `supabaseAdmin.auth.admin...`, `supabaseAdmin.storage...`. La primera vez que se
 * accede a una propiedad, se materializa el cliente real (lanzando si falta config).
 */
export const supabaseAdmin: SupabaseClient = new Proxy({} as SupabaseClient, {
  get(_target, prop, receiver) {
    const real = supabaseAdminClient();
    const value = Reflect.get(real as object, prop, receiver);
    return typeof value === "function" ? value.bind(real) : value;
  },
});
