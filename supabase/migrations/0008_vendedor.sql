-- 0008_vendedor.sql — FUNDACIÓN del rol VENDEDOR (artesano) + invitación por token.
-- Marketplace curado: el admin invita, nadie se registra solo (ver
-- docs/INVITACION_ACCESO.md). Espejo del patrón admin (0002/0006). Idempotente.
--
-- Qué añade:
--   1. artesanos.user_id  → eslabón auth.user ⇄ artesano (nullable hasta el claim).
--   2. public.invitaciones → token HASHEADO, un solo uso, TTL, ligado a un artesano.
--   3. es_vendedor() / mi_artesano_id() → SECURITY DEFINER search_path='' STABLE.
--   4. RLS "dueño": el vendedor VE/EDITA solo SU artesano y SUS productos.
--   5. RLS de storage: el vendedor escribe solo bajo vendedor/{su_artesano_id}/.
--
-- NO mueve dinero. Cae bajo el gate del CLAUDE.md "preguntar antes de cambiar RLS".
-- Requiere: 0001 (artesanos/productos), 0002 (is_admin/touch_updated_at).

-- ============================ 1) ENLACE user_id ============================
-- Nullable: el artesano existe (creado por el admin en estado invitado) ANTES de
-- que reclame la cuenta. UNIQUE: un auth.user posee a lo más un artesano (1:1).
-- on delete set null: si se borra el auth.user, el artesano queda "huérfano" pero
-- no se pierde (el admin lo puede reinvitar), en lugar de borrarse en cascada.
alter table public.artesanos
  add column if not exists user_id uuid references auth.users (id) on delete set null;

create unique index if not exists artesanos_user_id_unique
  on public.artesanos (user_id) where user_id is not null;

-- ============================ 2) INVITACIONES ============================
-- El token en claro NUNCA se guarda: se guarda su hash (sha256 hex). Si se filtra
-- la BD no hay tokens usables. `usado_en`/`revocada_en` implementan el "un solo uso"
-- y la revocación; `expira_en` el TTL (7 días por defecto, decidido en el claim).
create table if not exists public.invitaciones (
  id uuid primary key default gen_random_uuid(),
  artesano_id uuid not null references public.artesanos (id) on delete cascade,
  token_hash text not null,                    -- sha256(token) en hex; el token en claro solo vive en el link
  email text,                                  -- opcional: solo referencia para el admin (no se confía para auth)
  expira_en timestamptz not null,              -- TTL; el server lo pone a now() + 7 días al crear
  usado_en timestamptz,                        -- se sella en el claim → un solo uso
  revocada_en timestamptz,                     -- el admin puede invalidarla antes de que se use
  creada_por uuid references auth.users (id) on delete set null,  -- admin que la generó (bitácora)
  created_at timestamptz not null default now()
);

-- El hash es la llave de búsqueda del claim y debe ser único (un token = una fila).
create unique index if not exists invitaciones_token_hash_unique
  on public.invitaciones (token_hash);
-- Filtro del panel admin: invitaciones vigentes de un artesano.
create index if not exists invitaciones_artesano_idx
  on public.invitaciones (artesano_id);

-- Una invitación es VÁLIDA (canjeable) solo si: no usada, no revocada y no expirada.
-- Función expuesta para que el claim (service_role/Edge) y las policies compartan
-- la MISMA definición de "válida". SECURITY DEFINER + search_path='' como is_admin().
create or replace function public.invitacion_valida(p_token_hash text)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
    select 1 from public.invitaciones i
    where i.token_hash = p_token_hash
      and i.usado_en is null
      and i.revocada_en is null
      and i.expira_en > now()
  );
$$;

-- OJO SUPABASE: los "default privileges" conceden EXECUTE directo a anon y
-- authenticated al CREAR la función, así que `revoke from public` NO basta —
-- hay que revocarlos EXPLÍCITAMENTE por nombre. Solo el backend privilegiado
-- (service_role) valida tokens en el claim; anon/authenticated no deben sondear
-- hashes (evita oráculo de existencia).
revoke all on function public.invitacion_valida(text) from public, anon, authenticated;
grant execute on function public.invitacion_valida(text) to service_role;

alter table public.invitaciones enable row level security;

-- Solo el admin gestiona invitaciones desde el panel (crear/listar/revocar). El
-- claim las consume con service_role (bypassa RLS) tras su propia authz.
drop policy if exists invitaciones_admin_all on public.invitaciones;
create policy invitaciones_admin_all on public.invitaciones
  for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- Superficie mínima (patrón 0006): nadie salvo el admin autenticado la toca vía API.
revoke all on public.invitaciones from anon;

-- ============================ 3) HELPERS DE ROL ============================
-- Espejo EXACTO de is_admin() (0002): SECURITY DEFINER lee public.artesanos SIN
-- pasar por la RLS del llamante (sin recursión), search_path='' fija el esquema,
-- (select auth.uid()) se cachea por query para buen plan en las policies.
create or replace function public.mi_artesano_id()
returns uuid
language sql
security definer
set search_path = ''
stable
as $$
  select a.id from public.artesanos a
  where a.user_id = (select auth.uid())
  limit 1;
$$;

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
  );
$$;

-- Revoca también el EXECUTE directo que Supabase concede a anon por default
-- (revoke from public NO basta). El vendedor es `authenticated`; anon no necesita
-- estos helpers (patrón 0006, superficie mínima).
revoke all on function public.mi_artesano_id() from public, anon;
revoke all on function public.es_vendedor() from public, anon;
grant execute on function public.mi_artesano_id() to authenticated;
grant execute on function public.es_vendedor() to authenticated;

-- ============================ 4) RLS "DUEÑO" — ARTESANOS ============================
-- El admin ya tiene sus policies (0002). Estas se COMBINAN con OR: un vendedor ve
-- SOLO su propia fila (incluye rfc/regimen_fiscal/clabe, que son SUYOS).
drop policy if exists artesanos_vendedor_select on public.artesanos;
create policy artesanos_vendedor_select on public.artesanos
  for select to authenticated
  using (user_id = (select auth.uid()));

-- El vendedor puede ACTUALIZAR solo su fila. OJO: RLS NO restringe QUÉ columnas se
-- escriben → el Server Action DEBE usar whitelist zod (sin mass assignment):
-- prohibido que el vendedor toque status/comisión/user_id/slug. `with check` con
-- la misma condición impide que se "regale" la fila a otro user_id.
drop policy if exists artesanos_vendedor_update on public.artesanos;
create policy artesanos_vendedor_update on public.artesanos
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- NO se dan policies INSERT/DELETE al vendedor: no se auto-crea ni se auto-borra
-- (eso lo hace el admin / el claim con service_role).

-- ============================ 4) RLS "DUEÑO" — PRODUCTOS ============================
-- El vendedor ve/edita SOLO productos de SU artesano. mi_artesano_id() resuelve el
-- dueño una sola vez por query. Estas policies conviven con las de admin (0002) y
-- con productos_publicados_select (0001) por OR.
drop policy if exists productos_vendedor_select on public.productos;
create policy productos_vendedor_select on public.productos
  for select to authenticated
  using (artesano_id = public.mi_artesano_id());

-- INSERT: la pieza nueva DEBE quedar ligada a su propio artesano. `with check`
-- fuerza artesano_id = el suyo → no puede crear piezas a nombre de otro.
drop policy if exists productos_vendedor_insert on public.productos;
create policy productos_vendedor_insert on public.productos
  for insert to authenticated
  with check (artesano_id = public.mi_artesano_id());

-- UPDATE: solo lo suyo, y no puede reasignar la pieza a otro artesano (check).
-- El Server Action además hace whitelist (sin tocar artesano_id/comisión).
drop policy if exists productos_vendedor_update on public.productos;
create policy productos_vendedor_update on public.productos
  for update to authenticated
  using (artesano_id = public.mi_artesano_id())
  with check (artesano_id = public.mi_artesano_id());

drop policy if exists productos_vendedor_delete on public.productos;
create policy productos_vendedor_delete on public.productos
  for delete to authenticated
  using (artesano_id = public.mi_artesano_id());

-- ============================ 5) RLS STORAGE — bucket 'piezas' ============================
-- El bucket 'piezas' ya existe (0003) y está blindado a admin (0005). Se AÑADE una
-- superficie de escritura para el vendedor, ACOTADA a la carpeta vendedor/{su_id}/…
-- La app sube a `vendedor/<artesano_id>/<uuid>.webp`. storage.foldername(name)[1]
-- = 'vendedor', [2] = el artesano_id → debe coincidir con mi_artesano_id().
-- Nunca puede escribir bajo la carpeta de otro vendedor ni sobre productos/artesanos/
-- (rutas del admin), y el admin conserva acceso total por sus policies de 0003/0005.
drop policy if exists piezas_vendedor_select on storage.objects;
create policy piezas_vendedor_select on storage.objects
  for select to authenticated
  using (
    bucket_id = 'piezas'
    and (storage.foldername(name))[1] = 'vendedor'
    and (storage.foldername(name))[2] = public.mi_artesano_id()::text
  );

drop policy if exists piezas_vendedor_insert on storage.objects;
create policy piezas_vendedor_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'piezas'
    and (storage.foldername(name))[1] = 'vendedor'
    and (storage.foldername(name))[2] = public.mi_artesano_id()::text
  );

drop policy if exists piezas_vendedor_update on storage.objects;
create policy piezas_vendedor_update on storage.objects
  for update to authenticated
  using (
    bucket_id = 'piezas'
    and (storage.foldername(name))[1] = 'vendedor'
    and (storage.foldername(name))[2] = public.mi_artesano_id()::text
  )
  with check (
    bucket_id = 'piezas'
    and (storage.foldername(name))[1] = 'vendedor'
    and (storage.foldername(name))[2] = public.mi_artesano_id()::text
  );

drop policy if exists piezas_vendedor_delete on storage.objects;
create policy piezas_vendedor_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'piezas'
    and (storage.foldername(name))[1] = 'vendedor'
    and (storage.foldername(name))[2] = public.mi_artesano_id()::text
  );

-- NOTA: el bucket 'piezas' es PÚBLICO de lectura por ruta. Los datos fiscales
-- (rfc/regimen_fiscal/clabe) viven en columnas RLS de public.artesanos, NUNCA aquí.
-- El bucket privado 'fiscal' (Constancia de Situación Fiscal) es de una migración
-- posterior, junto con Stripe Connect.
