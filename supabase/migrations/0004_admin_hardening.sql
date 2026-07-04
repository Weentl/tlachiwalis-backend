-- 0004_admin_hardening.sql — Endurecimiento del admin (edge cases). Idempotente.
-- Ejecutar tras 0003.

-- 1) updated_at en artesanos → locking optimista (evita lost-update entre admins).
alter table public.artesanos add column if not exists updated_at timestamptz not null default now();
drop trigger if exists artesanos_touch_updated_at on public.artesanos;
create trigger artesanos_touch_updated_at
  before update on public.artesanos
  for each row execute function public.touch_updated_at();

-- 2) Unicidad de datos fiscales sensibles (parcial: solo cuando no son nulos).
--    Evita que dos artesanos compartan RFC o CLABE por error de captura.
create unique index if not exists artesanos_rfc_unique on public.artesanos (rfc) where rfc is not null;
create unique index if not exists artesanos_clabe_unique on public.artesanos (clabe) where clabe is not null;

-- 3) Constraints de formato/rango (defensa en profundidad; el servidor ya valida con zod).
alter table public.productos drop constraint if exists productos_precio_max;
alter table public.productos add constraint productos_precio_max
  check (precio_centavos <= 100000000); -- tope $1,000,000 MXN
alter table public.artesanos drop constraint if exists artesanos_clabe_fmt;
alter table public.artesanos add constraint artesanos_clabe_fmt
  check (clabe is null or clabe ~ '^[0-9]{18}$');
alter table public.artesanos drop constraint if exists artesanos_rfc_fmt;
alter table public.artesanos add constraint artesanos_rfc_fmt
  check (rfc is null or rfc ~ '^[A-ZÑ&]{3,4}[0-9]{6}[A-Z0-9]{3}$');

-- 4) Índices para los filtros del admin.
create index if not exists artesanos_oficio_idx on public.artesanos (oficio);
create index if not exists artesanos_region_idx on public.artesanos (region);
create index if not exists artesanos_status_idx on public.artesanos (status);

-- 5) Normalización de datos legacy del seed para que casen con el catálogo de estados.
update public.productos set region = 'Estado de México' where region = 'Edo. de México';
update public.artesanos set region = 'Estado de México' where region = 'Edo. de México';

-- 6) Borrado SEGURO de artesano: despublica y desvincula sus piezas, luego borra.
--    Atómico (una transacción) + idempotente. SECURITY DEFINER con check is_admin().
--    Resuelve el edge case "¿qué pasa con las piezas al borrar un artesano?":
--    las piezas NO se borran; pasan a 'borrador' (salen del público) y quedan sin
--    artesano asignado para que el admin las reasigne o elimine.
create or replace function public.eliminar_artesano_seguro(p_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_afectadas integer;
begin
  if not public.is_admin() then
    raise exception 'no autorizado';
  end if;
  update public.productos
    set status = 'borrador', artesano_id = null
    where artesano_id = p_id;
  get diagnostics v_afectadas = row_count;
  delete from public.artesanos where id = p_id;
  return v_afectadas; -- nº de piezas despublicadas
end;
$$;
revoke all on function public.eliminar_artesano_seguro(uuid) from public;
grant execute on function public.eliminar_artesano_seguro(uuid) to authenticated;
