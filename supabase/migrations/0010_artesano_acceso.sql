-- 0010_artesano_acceso.sql — CONTROL DE ACCESO del artesano (seguridad operativa).
-- Hace que `artesanos.status` gobierne el ACCESO de vendedor, no solo una etiqueta:
--   status='activo'  → puede entrar a su panel y operar.
--   status='pausado' → ACCESO CORTADO al instante (login, RLS de productos y storage).
-- Así el admin puede DESACTIVAR un artesano (p.ej. cuenta comprometida) desde el panel,
-- sin service_role: es_vendedor()/mi_artesano_id() dejan de resolver para él.
-- Idempotente. Espejo del patrón de 0008 (SECURITY DEFINER, search_path='').
-- NO borra nada. NO mueve dinero. Cae bajo el gate del CLAUDE.md (cambia funciones de authz).

-- mi_artesano_id(): solo resuelve al artesano si está ACTIVO. NULL si pausado → el RLS
-- "dueño" de productos (0008/0009) y de storage niega todo lo suyo (NULL no casa con nada).
create or replace function public.mi_artesano_id()
returns uuid
language sql
security definer
set search_path = ''
stable
as $$
  select a.id from public.artesanos a
  where a.user_id = (select auth.uid())
    and a.status = 'activo'
  limit 1;
$$;

-- es_vendedor(): false si el artesano está pausado → requireVendedor() y el login de
-- vendedor lo rebotan a /vendedor/login (defensa en profundidad sobre la RLS).
create or replace function public.es_vendedor()
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
    select 1 from public.artesanos a
    where a.user_id = (select auth.uid())
      and a.status = 'activo'
  );
$$;

-- Re-fijar la superficie de EXECUTE (patrón 0006 + corrección del gotcha de Supabase:
-- los default privileges conceden EXECUTE directo a anon/authenticated, hay que
-- revocarlos por nombre). Estas funciones son solo para `authenticated`.
revoke all on function public.mi_artesano_id() from public, anon;
revoke all on function public.es_vendedor() from public, anon;
grant execute on function public.mi_artesano_id() to authenticated;
grant execute on function public.es_vendedor() to authenticated;
