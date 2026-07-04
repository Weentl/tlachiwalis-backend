-- 0027 — Flags de curaduría + fecha de publicación en el storefront
-- Habilita los carriles del marketplace: "Recién del taller" (orden por publicado_en),
-- "En tendencia" (flag curado desde admin) y "Destacados" (flag). MVP curado con booleans;
-- cuando haya tráfico real se sustituye por métricas. NO se inventa un "algoritmo" fingido.

alter table public.productos
  add column if not exists destacado boolean not null default false,
  add column if not exists tendencia boolean not null default false;

-- Amplía la vista: expone publicado_en (created_at), destacado y tendencia.
-- Conserva security_invoker (la RLS del llamante filtra a 'publicado') y los grants.
create or replace view public.productos_storefront
with (security_invoker = true) as
  select
    p.id, p.nombre, p.maker, p.oficio, p.region, p.precio_centavos, p.imagen,
    p.descripcion, p.tecnica, p.materiales, p.medidas,
    p.precio_centavos + coalesce(
      (select min(pv.precio_delta_centavos)
         from public.producto_variantes pv
        where pv.producto_id = p.id and pv.activa = true), 0) as precio_desde,
    coalesce(
      (select sum(i.disponible)
         from public.producto_variantes pv
         join public.inventario i on i.variante_id = pv.id
        where pv.producto_id = p.id and pv.activa = true), 0::bigint) as disponible_total,
    p.artesano_id,
    a.slug as artesano_slug,
    p.categoria_id,
    p.tipo_producto,
    p.created_at as publicado_en,
    p.destacado,
    p.tendencia
  from public.productos p
  left join public.artesanos_publicos a on a.id = p.artesano_id;

revoke all on public.productos_storefront from anon, authenticated;
grant select on public.productos_storefront to anon, authenticated;
