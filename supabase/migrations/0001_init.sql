-- Tlachiwalis — esquema inicial (artesanos + productos) con RLS.
-- Ejecutar en el SQL Editor de Supabase (o con la CLI).

create extension if not exists pgcrypto;

-- ============================ ARTESANOS ============================
create table if not exists public.artesanos (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null,
  nombre text not null,
  semblanza text,
  region text,
  oficio text,
  foto_url text,
  -- Datos fiscales SENSIBLES: nunca se exponen al público (ver vista artesanos_publicos).
  rfc text,
  regimen_fiscal text,
  clabe text,
  status text not null default 'activo' check (status in ('activo', 'pausado')),
  created_at timestamptz not null default now()
);

-- ============================ PRODUCTOS ============================
create table if not exists public.productos (
  id text primary key,                         -- slug corto tipo 'tal-01' (coincide con la URL)
  artesano_id uuid references public.artesanos (id) on delete set null,
  nombre text not null,
  maker text,                                  -- nombre del taller (denormalizado para lectura pública)
  oficio text not null,
  region text not null,
  precio_centavos integer not null check (precio_centavos >= 0),
  moneda text not null default 'MXN',
  imagen text,
  descripcion text,
  tecnica text,
  materiales text,
  medidas text,
  status text not null default 'publicado' check (status in ('borrador', 'publicado', 'agotado')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists productos_oficio_idx on public.productos (oficio);
create index if not exists productos_region_idx on public.productos (region);
create index if not exists productos_status_idx on public.productos (status);
create index if not exists productos_artesano_idx on public.productos (artesano_id);

-- ============================ RLS ============================
alter table public.artesanos enable row level security;
alter table public.productos enable row level security;

-- Productos: el público (anon) solo ve lo PUBLICADO.
drop policy if exists productos_publicados_select on public.productos;
create policy productos_publicados_select on public.productos
  for select to anon, authenticated
  using (status = 'publicado');

-- Artesanos: la tabla base NO es legible por anon (protege rfc / regimen / clabe).
-- (Sin policy de select para anon => RLS deniega el acceso directo.)
-- El público lee solo campos seguros vía esta vista:
create or replace view public.artesanos_publicos as
  select id, slug, nombre, semblanza, region, oficio, foto_url
  from public.artesanos
  where status = 'activo';

grant select on public.artesanos_publicos to anon, authenticated;

-- NOTA: el panel admin (fase 2) usará la service_role key (bypassa RLS) desde el servidor,
-- con su propia verificación de rol. Las políticas de escritura para vendedores se agregan
-- en una migración posterior cuando exista auth + rol vendedor.
