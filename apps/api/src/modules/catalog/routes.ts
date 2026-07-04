import { Router } from "express";
import { supabaseAdmin } from "../../supabase";

export const catalogRouter = Router();

// GET /catalog/products  — lista de piezas publicadas
catalogRouter.get("/products", async (_req, res) => {
  try {
    const { data, error } = await supabaseAdmin
      .from("productos")
      .select("id,nombre,maker,oficio,region,precio_centavos,imagen,status")
      .eq("status", "publicado")
      .order("created_at", { ascending: true });
    if (error) return res.status(500).json({ error: error.message });
    res.json({ products: data ?? [] });
  } catch (e) {
    res.status(500).json({ error: e instanceof Error ? e.message : "error" });
  }
});

// GET /catalog/products/:id  — una pieza
// IMPORTANTE: supabaseAdmin usa la SECRET key y BYPASSA RLS. Este endpoint es
// PÚBLICO, así que la regla de negocio (solo 'publicado') y la proyección de
// columnas se aplican EXPLÍCITAMENTE aquí — nunca select('*') ni sin filtro,
// o se filtrarían borradores/agotados y columnas sensibles futuras.
const COLS_PUBLICAS =
  "id,nombre,maker,oficio,region,precio_centavos,moneda,imagen,descripcion,tecnica,materiales,medidas,status";
catalogRouter.get("/products/:id", async (req, res) => {
  try {
    const { data, error } = await supabaseAdmin
      .from("productos")
      .select(COLS_PUBLICAS)
      .eq("id", req.params.id)
      .eq("status", "publicado")
      .maybeSingle();
    if (error) return res.status(500).json({ error: error.message });
    if (!data) return res.status(404).json({ error: "no encontrada" });
    res.json({ product: data });
  } catch (e) {
    res.status(500).json({ error: e instanceof Error ? e.message : "error" });
  }
});
