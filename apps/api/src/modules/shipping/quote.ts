import { supabaseAdmin } from "../../supabase";

// Motor de envíos (MVP): tarifa por ZONA (nacional / extendida por CP) + PESO. AUTORIDAD del backend
// (nunca se confía en un monto de envío del cliente). El envío se queda en la plataforma (no se
// dispersa al artesano). Reemplazable por la lista oficial del courier / Skydropx más adelante.

export type ItemPeso = { pesoGramos: number | null; cantidad: number };

export type CotizacionEnvio = {
  zona: "nacional" | "extendida";
  nombre: string;
  costoCentavos: number;
  diasMin: number;
  diasMax: number;
  requiereCoordinacion: boolean;
  nota: string | null;
  gratis: boolean;
  pesoGramos: number;
};

type ZonaRow = {
  clave: string;
  nombre: string;
  tarifa_base_centavos: number;
  tarifa_kg_extra_centavos: number;
  dias_min: number;
  dias_max: number;
  requiere_coordinacion: boolean;
  nota: string | null;
};

// Cotización nacional de respaldo si faltara la tabla (nunca debería pasar tras la migración 0035).
const FALLBACK: ZonaRow = {
  clave: "nacional",
  nombre: "Envío nacional",
  tarifa_base_centavos: 9900,
  tarifa_kg_extra_centavos: 3500,
  dias_min: 3,
  dias_max: 6,
  requiere_coordinacion: false,
  nota: null,
};

function cpNormalizar(cp: string | null | undefined): string {
  return (cp ?? "").replace(/\D/g, "").slice(0, 5);
}

export async function cotizarEnvio(
  cp: string | null | undefined,
  items: ItemPeso[],
  subtotalCentavos: number,
): Promise<CotizacionEnvio> {
  const { data: cfg } = await supabaseAdmin
    .from("envio_config")
    .select("peso_default_gramos,umbral_gratis_centavos")
    .eq("id", 1)
    .maybeSingle();
  const pesoDefault = (cfg as { peso_default_gramos?: number } | null)?.peso_default_gramos ?? 800;
  const umbral = (cfg as { umbral_gratis_centavos?: number | null } | null)?.umbral_gratis_centavos ?? null;

  // Peso total: cada ítem sin peso usa el default (por unidad).
  const pesoGramos = items.reduce(
    (s, it) => s + (it.pesoGramos && it.pesoGramos > 0 ? it.pesoGramos : pesoDefault) * Math.max(1, it.cantidad),
    0,
  );

  // Zona por CP: extendida si el CP empieza con algún prefijo de la lista.
  const cpNorm = cpNormalizar(cp);
  let clave = "nacional";
  if (cpNorm) {
    const { data: prefijos } = await supabaseAdmin.from("envio_cp_extendido").select("prefijo");
    const lista = (prefijos ?? []) as { prefijo: string }[];
    if (lista.some((p) => p.prefijo && cpNorm.startsWith(p.prefijo))) clave = "extendida";
  }

  const { data: zData } = await supabaseAdmin
    .from("envio_zonas")
    .select("clave,nombre,tarifa_base_centavos,tarifa_kg_extra_centavos,dias_min,dias_max,requiere_coordinacion,nota")
    .eq("clave", clave)
    .eq("activa", true)
    .maybeSingle();
  const z = (zData as ZonaRow | null) ?? FALLBACK;

  const kg = Math.max(1, Math.ceil(pesoGramos / 1000));
  const extraKg = kg - 1;
  let costo = z.tarifa_base_centavos + extraKg * z.tarifa_kg_extra_centavos;

  const gratis = umbral != null && subtotalCentavos >= umbral;
  if (gratis) costo = 0;

  return {
    zona: z.clave === "extendida" ? "extendida" : "nacional",
    nombre: z.nombre,
    costoCentavos: costo,
    diasMin: z.dias_min,
    diasMax: z.dias_max,
    requiereCoordinacion: z.requiere_coordinacion,
    nota: z.nota,
    gratis,
    pesoGramos,
  };
}

// Trae el peso de cada producto para armar los ItemPeso a partir de {productoId, cantidad}.
export async function pesosDeProductos(
  items: { productoId: string; cantidad: number }[],
): Promise<ItemPeso[]> {
  const ids = [...new Set(items.map((i) => i.productoId))];
  const { data } = await supabaseAdmin
    .from("productos")
    .select("id,peso_gramos")
    .in("id", ids);
  const pesoPorId = new Map(
    ((data ?? []) as { id: string; peso_gramos: number | null }[]).map((r) => [r.id, r.peso_gramos]),
  );
  return items.map((i) => ({ pesoGramos: pesoPorId.get(i.productoId) ?? null, cantidad: i.cantidad }));
}
