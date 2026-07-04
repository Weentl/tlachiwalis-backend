-- 0028 — Fix P0: la galería multi-foto es invisible para el comprador (anon)
-- Los índices de expresión de producto_imagenes (producto_imagenes_orden_unq usa
-- coalesce(variante_id, uuid_nil())) y de producto_variantes (opciones_norm) requieren EXECUTE
-- de esas funciones cuando el planner los usa (p.ej. el ORDER BY de la galería). La 0020 devolvió
-- EXECUTE solo a `authenticated` (arregló el wizard del vendedor), pero el storefront lo lee como
-- `anon` → "permission denied for function uuid_nil" → getPiezaExtra recibe imgs=null → la PDP cae
-- al fallback de UNA sola foto. Estas funciones son triviales/constantes (cero riesgo). La RLS sigue
-- limitando QUÉ filas ve anon (solo productos 'publicado'); esto solo permite evaluar el índice.

grant execute on function public.uuid_nil() to anon;
grant execute on function public.opciones_norm(jsonb) to anon;
