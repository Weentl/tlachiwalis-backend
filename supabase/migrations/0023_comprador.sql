-- 0023_comprador.sql — CUENTAS DE COMPRADOR. [GATE RLS — verificar con anon/otro usuario]
-- Un comprador = cualquier auth.user. No choca con artesanos (tienen fila en public.artesanos)
-- ni con admin (is_admin()). Sin datos de tarjeta (eso va en el pago, con Stripe).

-- ── perfil 1:1 con auth.users ────────────────────────────────────────────────
create table if not exists public.perfiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  nombre text,
  telefono text,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.perfiles enable row level security;
-- Self-only: cada quien ve/edita SOLO su perfil. anon sin acceso.
drop policy if exists perfiles_self_select on public.perfiles;
create policy perfiles_self_select on public.perfiles for select to authenticated using (user_id = auth.uid());
drop policy if exists perfiles_self_insert on public.perfiles;
create policy perfiles_self_insert on public.perfiles for insert to authenticated with check (user_id = auth.uid());
drop policy if exists perfiles_self_update on public.perfiles;
create policy perfiles_self_update on public.perfiles for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
revoke all on public.perfiles from anon;

-- ── direcciones de envío (N por comprador). SIN datos de tarjeta ─────────────
create table if not exists public.direcciones (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  etiqueta text,             -- "Casa", "Oficina"
  destinatario text,
  telefono text,
  calle text,
  colonia text,
  ciudad text,
  estado text,
  cp text,
  referencias text,
  es_principal boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.direcciones enable row level security;
drop policy if exists direcciones_self_all on public.direcciones;
create policy direcciones_self_all on public.direcciones for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
revoke all on public.direcciones from anon;
create index if not exists direcciones_user_idx on public.direcciones(user_id);

-- ── updated_at (reusa touch_updated_at existente) ────────────────────────────
drop trigger if exists perfiles_touch_updated_at on public.perfiles;
create trigger perfiles_touch_updated_at before update on public.perfiles
  for each row execute function public.touch_updated_at();
drop trigger if exists direcciones_touch_updated_at on public.direcciones;
create trigger direcciones_touch_updated_at before update on public.direcciones
  for each row execute function public.touch_updated_at();

-- ── alta automática de perfil al nacer cualquier auth.user ───────────────────
-- SECURITY DEFINER (inserta en perfiles saltando RLS). `on conflict do nothing` = idempotente e
-- INOFENSIVO para admins/artesanos (que también nacen vía service_role): solo les crea un perfil
-- vacío, no rompe el claim de artesano. Toma nombre/avatar de user_metadata (register / Google).
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.perfiles (user_id, nombre, telefono, avatar_url)
  values (
    new.id,
    coalesce(
      new.raw_user_meta_data->>'nombre',
      new.raw_user_meta_data->>'full_name',
      new.raw_user_meta_data->>'name'
    ),
    new.raw_user_meta_data->>'telefono',
    new.raw_user_meta_data->>'avatar_url'
  )
  on conflict (user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
