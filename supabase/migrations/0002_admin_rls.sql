-- supabase/migrations/0002_admin_rls.sql
-- Tlachiwalis fase 2: rol admin SOLO con RLS (sin service_role).
-- Ejecutar tras 0001. Idempotente.

-- ============================ ADMINS ============================
create table if not exists public.admins (
  user_id uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.admins enable row level security;

-- is_admin(): SECURITY DEFINER + search_path vacio.
--  - search_path='' evita "function search path mutable" y obliga a calificar esquemas.
--  - SECURITY DEFINER lee public.admins SIN pasar por RLS del llamante (sin recursion).
--  - (select auth.uid()) cachea el valor por query (mejor plan en politicas RLS).
--  - auth.uid() y now() ya estan calificados (auth / pg_catalog), seguros con search_path=''.
create or replace function public.is_admin()
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
    select 1 from public.admins a
    where a.user_id = (select auth.uid())
  );
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to anon, authenticated;

-- La tabla admins solo la maneja un admin. El PRIMER admin se siembra por psql
-- (superusuario salta RLS). Esto bloquea auto-escalada de privilegios.
drop policy if exists admins_admin_select on public.admins;
create policy admins_admin_select on public.admins
  for select to authenticated using (public.is_admin());

drop policy if exists admins_admin_write on public.admins;
create policy admins_admin_write on public.admins
  for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- ============================ PRODUCTOS ============================
-- 0001 ya tiene productos_publicados_select (anon+authenticated: status='publicado').
-- Las policies SELECT se combinan con OR para authenticated => el admin ve TODO.
drop policy if exists productos_admin_select on public.productos;
create policy productos_admin_select on public.productos
  for select to authenticated using (public.is_admin());

drop policy if exists productos_admin_insert on public.productos;
create policy productos_admin_insert on public.productos
  for insert to authenticated with check (public.is_admin());

drop policy if exists productos_admin_update on public.productos;
create policy productos_admin_update on public.productos
  for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists productos_admin_delete on public.productos;
create policy productos_admin_delete on public.productos
  for delete to authenticated using (public.is_admin());

-- Mantener updated_at fresco en UPDATE sin confiar en la app.
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists productos_touch_updated_at on public.productos;
create trigger productos_touch_updated_at
  before update on public.productos
  for each row execute function public.touch_updated_at();

-- ============================ ARTESANOS ============================
-- En 0001 la tabla base NO tiene policy SELECT => anon y authenticated-no-admin
-- quedan DENEGADOS (rfc/regimen_fiscal/clabe protegidos). El publico usa la vista
-- public.artesanos_publicos (sin datos fiscales). Solo el admin lee la tabla completa:
drop policy if exists artesanos_admin_select on public.artesanos;
create policy artesanos_admin_select on public.artesanos
  for select to authenticated using (public.is_admin());

drop policy if exists artesanos_admin_insert on public.artesanos;
create policy artesanos_admin_insert on public.artesanos
  for insert to authenticated with check (public.is_admin());

drop policy if exists artesanos_admin_update on public.artesanos;
create policy artesanos_admin_update on public.artesanos
  for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists artesanos_admin_delete on public.artesanos;
create policy artesanos_admin_delete on public.artesanos
  for delete to authenticated using (public.is_admin());

-- NOTA: RLS NO restringe QUE columnas se escriben; el Server Action DEBE usar zod
-- whitelist (sin mass assignment) y el servidor es la autoridad de precio_centavos.
