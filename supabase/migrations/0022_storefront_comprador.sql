-- 0022_storefront_comprador.sql — capa PÚBLICA del comprador. [GATE RLS — verificar con anon]
--
-- (1) Amplía `artesanos_publicos` (SECURITY DEFINER) con SOLO columnas de marca NO sensibles
--     (para la página pública del artesano). NUNCA expone rfc/regimen_fiscal/clabe/stripe_account_id/
--     telefono/direccion/fecha_nacimiento/contacto/nombres/apellidos legales/cobros_*.
-- (2) Amplía `productos_storefront` (PRESERVANDO security_invoker=true → anon solo ve 'publicado')
--     con artesano_id, artesano_slug, categoria_id, tipo_producto.
-- (3) CIERRA una vulnerabilidad pre-existente: anon/authenticated tenían grants de escritura sobre
--     estas vistas; como `artesanos_publicos` es DEFINER y auto-actualizable, anon podía ESCRIBIR
--     en `artesanos` bypasseando RLS. Se revoca todo menos SELECT (son vistas de solo lectura).

-- ── (1) artesanos_publicos: SECURITY DEFINER (anon lo lee aunque no pueda leer la tabla base),
--        filtrado a status='activo', SOLO columnas públicas. Mantiene las 7 originales en orden
--        (id,slug,nombre,semblanza,region,oficio,foto_url) y añade marca al final.
create or replace view public.artesanos_publicos as
  select
    id, slug, nombre, semblanza, region, oficio, foto_url,
    foto_portada, redes, envia_nacional, tipo_vendedor, nombre_negocio, taller,
    anios_experiencia, num_personas
  from public.artesanos
  where status = 'activo';

-- ── (2) productos_storefront: security_invoker=true (hereda RLS de solo-'publicado'). Reproduce
--        las columnas históricas + precio_desde/disponible_total y AÑADE artesano/categoria/tipo.
create or replace view public.productos_storefront
with (security_invoker = true) as
  select
    p.id, p.nombre, p.maker, p.oficio, p.region, p.precio_centavos, p.imagen,
    p.descripcion, p.tecnica, p.materiales, p.medidas,
    p.precio_centavos + coalesce((
      select min(pv.precio_delta_centavos)
      from public.producto_variantes pv
      where pv.producto_id = p.id and pv.activa = true), 0) as precio_desde,
    coalesce((
      select sum(i.disponible)
      from public.producto_variantes pv
      join public.inventario i on i.variante_id = pv.id
      where pv.producto_id = p.id and pv.activa = true), 0::bigint) as disponible_total,
    p.artesano_id,
    a.slug as artesano_slug,
    p.categoria_id,
    p.tipo_producto
  from public.productos p
  left join public.artesanos_publicos a on a.id = p.artesano_id;

-- ── (3) Cerrar el vector de escritura: vistas PÚBLICAS = solo lectura para anon/authenticated.
revoke all on public.artesanos_publicos from anon, authenticated;
grant select on public.artesanos_publicos to anon, authenticated;
revoke all on public.productos_storefront from anon, authenticated;
grant select on public.productos_storefront to anon, authenticated;
