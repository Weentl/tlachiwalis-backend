-- 0009_producto_modelo.sql — FASE 1: modelo de producto (variantes + inventario + galería).
-- Evolución del catálogo (ver docs/MODELO_PRODUCTO.md). ADITIVA, NO DESTRUCTIVA, IDEMPOTENTE.
-- NO es el wizard (eso es Fase 3). NO cambia el pipeline sharp ni el switch a paths relativos
-- de la app (eso es Fase 2). NO mueve dinero. NO toca las tasas fiscales.
--
-- DISCREPANCIA DE NUMERACIÓN (respetada): el blueprint planeó 0008=variantes, pero el
-- repo REAL usó 0008_vendedor.sql. Fase 1 renumera. Este archivo contiene las tres partes
-- que el blueprint separaba (0009 variantes/inventario/galería, 0010 backfill, 0011 vista
-- compat) en un solo entregable revisable. El switch de catalog.ts a la vista es un cambio
-- de código SEPARADO (último paso de Fase 1), no SQL.
--
-- Requiere: 0001 (productos/artesanos, productos_publicados_select),
--           0002 (is_admin(), touch_updated_at()),
--           0007 (categorias/atributos/atributo_opciones/categoria_atributos),
--           0008 (es_vendedor()/mi_artesano_id(), RLS dueño sobre productos).
--
-- Cae bajo el gate del CLAUDE.md "preguntar antes de cambiar RLS/triggers de status".
-- Los triggers de derivación de portada y de status 'agotado' se DEJAN LISTOS aquí
-- (el blueprint los ubicaba en 0012) porque son inseparables de las tablas nuevas.

create extension if not exists pgcrypto;  -- gen_random_uuid (idempotente; ya en 0001)

-- ════════════════════════════════════════════════════════════════════════════
-- PARTE A — COLUMNAS NUEVAS EN public.productos (aditivas; sin drop/alter-type)
-- ════════════════════════════════════════════════════════════════════════════
-- precio_centavos EXISTENTE pasa a ser PRECIO BASE (las variantes guardan un delta).
-- medidas (text) NO se borra: se DEPRECA conceptualmente a "descripcion_medidas" para el
-- comprador; las medidas ESTRUCTURADAS viven en `atributos` jsonb. imagen (text) se conserva
-- como portada denormalizada, sincronizada por trigger desde producto_imagenes.

alter table public.productos
  -- Categoría: NULL en la migración (backfill best-effort). NOT NULL 'al publicar' vía
  -- CHECK condicional más abajo, para no romper borradores/auto-guardado ni las filas que
  -- queden sin categoría tras el backfill hasta revisión del admin.
  add column if not exists categoria_id smallint references public.categorias (id) on delete set null,
  -- Atributos DESCRIPTIVOS (no-variante): material, técnica estructurada, diametro_cm,
  -- alto_cm, apto_alimentos… VALIDADOS por trigger contra categoria_atributos con
  -- es_variacion=false. Los EJES de variación (talla/color) NO van aquí: viven en
  -- producto_variantes.opciones.
  add column if not exists atributos jsonb not null default '{}'::jsonb,
  -- Forma del producto. 'unico' = pieza única (stock 1, sin ejes). 'stock_simple' = un
  -- SKU con stock>1. 'con_variantes' = múltiples combinaciones.
  add column if not exists tipo_producto text not null default 'unico',
  -- Dimensiones de EMPAQUE para ENVÍO (enteros base: gramos y milímetros). Distintas de
  -- las medidas de la PIEZA (esas van en `atributos`/`medidas`).
  add column if not exists peso_gramos int,
  add column if not exists largo_mm int,
  add column if not exists ancho_mm int,
  add column if not exists alto_mm int,
  -- SAT: override opcional a nivel producto; el default hereda de categorias.clave_prod_serv
  -- (0007). SOLO admin lo edita (whitelist en el Server Action). El artesano NUNCA lo elige.
  add column if not exists clave_prod_serv text,
  -- Gancho fiscal/envío: default = precio_centavos (se llena en backfill / al crear).
  add column if not exists valor_declarado_centavos int;

-- CHECK de tipo_producto: se AÑADE por nombre solo si no existe (add-if-not-exists manual
-- porque Postgres no soporta "add constraint if not exists"). NOT VALID para no bloquear
-- filas legado que ya cumplen (todas nacen con default 'unico').
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'productos_tipo_producto_check'
  ) then
    alter table public.productos
      add constraint productos_tipo_producto_check
      check (tipo_producto in ('unico', 'stock_simple', 'con_variantes')) not valid;
  end if;
end $$;

-- NOTA (Fase 1): la regla "publicado ⇒ categoria_id NOT NULL" se DIFIERE a Fase 3, cuando el
-- wizard permita elegir categoría. Añadirla ahora —aun NOT VALID— ROMPERÍA la EDICIÓN de los
-- productos publicados legados sin categoría: NOT VALID no revalida el histórico, pero CUALQUIER
-- update posterior a esas filas (incluido el backfill E.1 y editar la pieza desde el admin)
-- dispara el check en la fila. Fase 3 la re-añadirá VALIDATED una vez categorizado todo el
-- catálogo (o vía el Server Action del wizard, que exigirá categoría al publicar).

create index if not exists productos_categoria_idx on public.productos (categoria_id);

-- ════════════════════════════════════════════════════════════════════════════
-- PARTE B — TABLAS NUEVAS: variantes, inventario, galería
-- ════════════════════════════════════════════════════════════════════════════

-- ── uuid_nil() helper: constante todo-ceros para el índice parcial de galería.
--    (COALESCE(variante_id, uuid_nil) da un discriminante estable para foto general.)
--    IMMUTABLE + search_path='' como slugify()/is_admin().
create or replace function public.uuid_nil()
returns uuid
language sql
immutable
set search_path = ''
as $$
  select '00000000-0000-0000-0000-000000000000'::uuid;
$$;

-- ── opciones_norm(): serializa un jsonb de opciones a texto CANÓNICO con claves ordenadas,
--    para el índice UNIQUE que evita combinaciones duplicadas por producto. IMMUTABLE
--    (requisito de índice de expresión). search_path='' + objetos calificados.
create or replace function public.opciones_norm(op jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select coalesce(
    (select string_agg(kv.key || '=' || (kv.value #>> '{}'), '|' order by kv.key)
       from pg_catalog.jsonb_each(coalesce(op, '{}'::jsonb)) as kv),
    ''
  );
$$;

-- ─────────────────────────── producto_variantes ───────────────────────────
-- TODO producto tiene ≥1 variante. Pieza única = variante default opciones={} stock=1,
-- autogenerada (el artesano nunca ve "variante"). El precio efectivo SIEMPRE se recalcula
-- en servidor = productos.precio_centavos + precio_delta_centavos (nunca se confía al cliente).
-- NOTA sobre la FK circular: producto_variantes.imagen_variante_id → producto_imagenes y
-- producto_imagenes.variante_id → producto_variantes se referencian mutuamente. La columna
-- imagen_variante_id se crea SIN su FK aquí; la FK se añade por ALTER TABLE (Parte B.bis)
-- una vez que producto_imagenes existe. Así el orden de creación no falla en un apply limpio.
create table if not exists public.producto_variantes (
  id uuid primary key default gen_random_uuid(),
  producto_id text not null references public.productos (id) on delete cascade,
  sku text not null,                              -- AUTOGENERADO server-side; default = <producto_id>||'-U'
  opciones jsonb not null default '{}'::jsonb,    -- SOLO ejes es_variacion, p.ej. {"talla":"M","color":"anil"}
  precio_delta_centavos int not null default 0,   -- delta sobre productos.precio_centavos
  imagen_variante_id uuid,                        -- FK a producto_imagenes(id) añadida en B.bis
  activa boolean not null default true,
  created_at timestamptz not null default now(),
  unique (producto_id, sku)
);

-- Una combinación de opciones no puede repetirse dentro del mismo producto (talla=M dos veces).
create unique index if not exists producto_variantes_opciones_unq
  on public.producto_variantes (producto_id, public.opciones_norm(opciones));

create index if not exists producto_variantes_producto_idx
  on public.producto_variantes (producto_id);

-- ─────────────────────────── inventario ───────────────────────────
-- 1:1 con la variante (PK = variante_id). disponible es GENERATED (stock - reservado).
-- Decremento atómico para el checkout FUTURO (evita sobreventa; regla del CLAUDE.md):
--   UPDATE public.inventario SET reservado = reservado + :q
--   WHERE variante_id = :v AND (stock - reservado) >= :q;
-- (o permitir_backorder=true salta la comprobación).
create table if not exists public.inventario (
  variante_id uuid primary key references public.producto_variantes (id) on delete cascade,
  stock int not null default 0 check (stock >= 0),
  reservado int not null default 0 check (reservado >= 0),
  disponible int generated always as (stock - reservado) stored,
  permitir_backorder boolean not null default false,
  updated_at timestamptz not null default now()
);

drop trigger if exists inventario_touch_updated_at on public.inventario;
create trigger inventario_touch_updated_at
  before update on public.inventario
  for each row execute function public.touch_updated_at();

-- ─────────────────────────── producto_imagenes ───────────────────────────
-- Galería. storage_path es RELATIVO ('productos/<uuid>.webp' o
-- 'vendedor/<artesano_id>/<uuid>.webp'), NUNCA una URL absoluta. La app construye la URL
-- pública con getPublicUrl(path). variante_id NULL = foto general de la pieza.
create table if not exists public.producto_imagenes (
  id uuid primary key default gen_random_uuid(),
  producto_id text not null references public.productos (id) on delete cascade,
  variante_id uuid references public.producto_variantes (id) on delete set null,  -- NULL = general
  storage_path text not null,                     -- RELATIVO al bucket 'piezas'; jamás URL absoluta
  alt text,                                       -- autollenado '<nombre>, <oficio> de <region>'
  orden smallint not null default 0,
  es_principal boolean not null default false,
  ancho int,
  alto int,
  bytes int,
  created_at timestamptz not null default now()
);

-- ── B.bis  FK circular diferida: producto_variantes.imagen_variante_id → producto_imagenes ──
-- Ambas tablas ya existen aquí. Se añade la FK solo si no está (add-constraint-if-not-exists
-- manual vía pg_constraint). ON DELETE SET NULL: borrar una foto no borra la variante.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'producto_variantes_imagen_fk'
  ) then
    alter table public.producto_variantes
      add constraint producto_variantes_imagen_fk
      foreign key (imagen_variante_id) references public.producto_imagenes (id) on delete set null;
  end if;
end $$;

create index if not exists producto_imagenes_producto_idx
  on public.producto_imagenes (producto_id);
create index if not exists producto_imagenes_variante_idx
  on public.producto_imagenes (variante_id);

-- Portada ÚNICA por índice parcial: una portada GENERAL por pieza…
create unique index if not exists producto_imagenes_portada_general_unq
  on public.producto_imagenes (producto_id)
  where es_principal and variante_id is null;

-- …y una portada por VARIANTE.
create unique index if not exists producto_imagenes_portada_variante_unq
  on public.producto_imagenes (variante_id)
  where es_principal and variante_id is not null;

-- Orden sin colisiones dentro de un mismo grupo (pieza-general o variante).
create unique index if not exists producto_imagenes_orden_unq
  on public.producto_imagenes (producto_id, coalesce(variante_id, public.uuid_nil()), orden);

-- ════════════════════════════════════════════════════════════════════════════
-- PARTE C — TRIGGERS DE VALIDACIÓN (JSONB híbrido) Y DERIVACIÓN
-- ════════════════════════════════════════════════════════════════════════════
-- Patrón de 0002/0007/0008: plpgsql, SET search_path='', todo objeto calificado (public.x).

-- ── C.1  Validación de productos.atributos (DESCRIPTIVOS, es_variacion=false) ──
-- Cada clave del jsonb debe: (a) existir en atributos.codigo, (b) estar declarada en
-- categoria_atributos para producto.categoria_id con es_variacion=false, (c) respetar el
-- tipo. Los REQUERIDOS NO se exigen aquí (se exigen al publicar, para no bloquear borradores).
-- Si categoria_id es NULL (borrador/backfill) y atributos={}, se acepta; con atributos
-- no vacíos sin categoría, se rechaza (no hay contra qué validar).
create or replace function public.validar_producto_atributos()
returns trigger
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  k text;
  v jsonb;
  a record;
begin
  if new.atributos is null or new.atributos = '{}'::jsonb then
    return new;
  end if;

  if new.categoria_id is null then
    raise exception 'productos.atributos no vacío requiere categoria_id (clave: %)',
      (select string_agg(key, ', ') from pg_catalog.jsonb_object_keys(new.atributos) as key);
  end if;

  for k, v in select key, value from pg_catalog.jsonb_each(new.atributos) loop
    -- El atributo debe existir Y estar declarado como DESCRIPTIVO (es_variacion=false)
    -- en la categoría del producto.
    select at.tipo into a
    from public.atributos at
    join public.categoria_atributos ca
      on ca.atributo_id = at.id
     and ca.categoria_id = new.categoria_id
     and ca.es_variacion = false
    where at.codigo = k;

    if not found then
      raise exception 'atributo "%" no es un atributo descriptivo válido de la categoría %',
        k, new.categoria_id;
    end if;

    -- Validación por tipo (mismo contrato que el zod del Server Action).
    if a.tipo = 'lista' then
      if v = 'null'::jsonb or jsonb_typeof(v) <> 'string'
         or not exists (
           select 1 from public.atributo_opciones ao
           join public.atributos at2 on at2.id = ao.atributo_id
           where at2.codigo = k and ao.valor = (v #>> '{}')
         ) then
        raise exception 'valor "%" no es una opción válida del atributo lista "%"', (v #>> '{}'), k;
      end if;
    elsif a.tipo = 'numero' then
      if jsonb_typeof(v) <> 'number' or (v #>> '{}')::numeric < 0 then
        raise exception 'atributo numérico "%" debe ser un número >= 0', k;
      end if;
    elsif a.tipo = 'booleano' then
      if jsonb_typeof(v) <> 'boolean' then
        raise exception 'atributo booleano "%" debe ser true/false', k;
      end if;
    elsif a.tipo = 'texto' then
      if jsonb_typeof(v) <> 'string' then
        raise exception 'atributo texto "%" debe ser string', k;
      end if;
    end if;
  end loop;

  return new;
end;
$$;

revoke all on function public.validar_producto_atributos() from public, anon, authenticated;

drop trigger if exists productos_validar_atributos on public.productos;
create trigger productos_validar_atributos
  before insert or update of atributos, categoria_id on public.productos
  for each row execute function public.validar_producto_atributos();

-- ── C.2  Validación de producto_variantes.opciones (EJES, es_variacion=true) ──
-- Solo claves declaradas es_variacion=true en la categoría del producto padre; valores en
-- atributo_opciones; y como MUCHO los ejes es_variacion definidos por la categoría (máx 2
-- por el modelado de 0007). Límite duro de 100 combinaciones por producto.
create or replace function public.validar_variante_opciones()
returns trigger
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  v_categoria smallint;
  v_status text;
  k text;
  v jsonb;
  n_combos int;
begin
  select p.categoria_id, p.status into v_categoria, v_status
  from public.productos p where p.id = new.producto_id;

  -- Límite duro de combinaciones por producto (excluyendo la propia fila en UPDATE).
  select count(*) into n_combos
  from public.producto_variantes pv
  where pv.producto_id = new.producto_id and pv.id <> new.id;
  if n_combos >= 100 then
    raise exception 'un producto no puede tener más de 100 variantes (producto %)', new.producto_id;
  end if;

  -- La variante default {} siempre es válida (pieza única / stock simple).
  if new.opciones is null or new.opciones = '{}'::jsonb then
    return new;
  end if;

  if v_categoria is null then
    raise exception 'variante con opciones requiere que el producto tenga categoria_id (producto %)',
      new.producto_id;
  end if;

  for k, v in select key, value from pg_catalog.jsonb_each(new.opciones) loop
    if not exists (
      select 1
      from public.atributos at
      join public.categoria_atributos ca
        on ca.atributo_id = at.id
       and ca.categoria_id = v_categoria
       and ca.es_variacion = true
      where at.codigo = k
    ) then
      raise exception 'opción "%" no es un eje de variación válido de la categoría %', k, v_categoria;
    end if;

    -- Los ejes de variación son siempre tipo 'lista' en el modelo → valor en atributo_opciones.
    if v = 'null'::jsonb or jsonb_typeof(v) <> 'string'
       or not exists (
         select 1 from public.atributo_opciones ao
         join public.atributos at2 on at2.id = ao.atributo_id
         where at2.codigo = k and ao.valor = (v #>> '{}')
       ) then
      raise exception 'valor "%" no es una opción válida del eje de variación "%"', (v #>> '{}'), k;
    end if;
  end loop;

  return new;
end;
$$;

revoke all on function public.validar_variante_opciones() from public, anon, authenticated;

drop trigger if exists producto_variantes_validar_opciones on public.producto_variantes;
create trigger producto_variantes_validar_opciones
  before insert or update of opciones, producto_id on public.producto_variantes
  for each row execute function public.validar_variante_opciones();

-- ── C.3  Sync de portada: producto_imagenes.es_principal (general) → productos.imagen ──
-- Denormaliza la portada general al legado productos.imagen (URL absoluta construida desde el
-- storage_path relativo), para no romper el render actual del storefront hasta Fase 2.
-- Fuente ÚNICA de verdad = la fila con es_principal AND variante_id IS NULL. Este trigger
-- corre en producto_imagenes; escribe productos.imagen. Recalcula desde la BD (no confía en
-- OLD/NEW aislados) para ser correcto ante INSERT/UPDATE/DELETE de la portada.
-- La URL pública es: <SUPABASE_URL>/storage/v1/object/public/piezas/<storage_path>.
-- El prefijo del host se toma de la config del proyecto (current_setting), con fallback a
-- ruta relativa /storage/... si no está seteado (la app resuelve el host).
create or replace function public.sync_portada_producto()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_producto text;
  v_path text;
  v_base text;
  v_url text;
begin
  v_producto := coalesce(new.producto_id, old.producto_id);

  select storage_path into v_path
  from public.producto_imagenes
  where producto_id = v_producto
    and es_principal
    and variante_id is null
  limit 1;

  if v_path is null then
    -- No hay portada general: no pisamos el legado (evita borrar la imagen actual por error).
    return coalesce(new, old);
  end if;

  -- Base pública del bucket. current_setting(..., true) => NULL si no existe (no error).
  v_base := current_setting('app.supabase_public_url', true);
  if v_base is null or v_base = '' then
    v_url := '/storage/v1/object/public/piezas/' || v_path;
  else
    v_url := rtrim(v_base, '/') || '/storage/v1/object/public/piezas/' || v_path;
  end if;

  update public.productos set imagen = v_url where id = v_producto and imagen is distinct from v_url;
  return coalesce(new, old);
end;
$$;

revoke all on function public.sync_portada_producto() from public, anon, authenticated;

drop trigger if exists producto_imagenes_sync_portada on public.producto_imagenes;
create trigger producto_imagenes_sync_portada
  after insert or delete or update of storage_path, es_principal, variante_id
  on public.producto_imagenes
  for each row execute function public.sync_portada_producto();

-- ── C.4  Derivación de status 'agotado' desde el inventario ──
-- Cuando SUM(inventario.disponible) sobre variantes ACTIVAS llega a 0, el producto pasa a
-- 'agotado'; si vuelve a haber disponible y estaba 'agotado', vuelve a 'publicado'. NUNCA
-- toca 'borrador' (respeta el trabajo en progreso). backorder mantiene "disponible".
-- Corre en inventario (after insert/update/delete) y recalcula desde la BD.
create or replace function public.derivar_status_agotado()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_producto text;
  v_disp bigint;
  v_status text;
  v_backorder boolean;
begin
  select pv.producto_id into v_producto
  from public.producto_variantes pv
  where pv.id = coalesce(new.variante_id, old.variante_id);

  if v_producto is null then
    return coalesce(new, old);
  end if;

  select p.status into v_status from public.productos p where p.id = v_producto;

  select coalesce(sum(i.disponible), 0),
         bool_or(coalesce(i.permitir_backorder, false))
    into v_disp, v_backorder
  from public.producto_variantes pv
  join public.inventario i on i.variante_id = pv.id
  where pv.producto_id = v_producto and pv.activa = true;

  if v_status = 'publicado' and v_disp <= 0 and not v_backorder then
    update public.productos set status = 'agotado' where id = v_producto;
  elsif v_status = 'agotado' and (v_disp > 0 or v_backorder) then
    update public.productos set status = 'publicado' where id = v_producto;
  end if;

  return coalesce(new, old);
end;
$$;

revoke all on function public.derivar_status_agotado() from public, anon, authenticated;

drop trigger if exists inventario_derivar_status on public.inventario;
create trigger inventario_derivar_status
  after insert or delete or update of stock, reservado, permitir_backorder
  on public.inventario
  for each row execute function public.derivar_status_agotado();

-- ════════════════════════════════════════════════════════════════════════════
-- PARTE D — RLS: 3 capas (público publicado / admin / vendedor dueño), espejo 0001-0008
-- ════════════════════════════════════════════════════════════════════════════
alter table public.producto_variantes enable row level security;
alter table public.inventario         enable row level security;
alter table public.producto_imagenes  enable row level security;

-- ── D.1  producto_variantes ──
-- SELECT público SOLO si el producto padre está 'publicado' (espejo productos_publicados_select
-- de 0001). Admin ALL (espejo 0002). Vendedor ALL acotado a su artesano (espejo 0008).
drop policy if exists producto_variantes_public_select on public.producto_variantes;
create policy producto_variantes_public_select on public.producto_variantes
  for select to anon, authenticated
  using (exists (
    select 1 from public.productos p
    where p.id = producto_variantes.producto_id and p.status = 'publicado'
  ));

drop policy if exists producto_variantes_admin_all on public.producto_variantes;
create policy producto_variantes_admin_all on public.producto_variantes
  for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists producto_variantes_vendedor_all on public.producto_variantes;
create policy producto_variantes_vendedor_all on public.producto_variantes
  for all to authenticated
  using (exists (
    select 1 from public.productos p
    where p.id = producto_variantes.producto_id
      and p.artesano_id = public.mi_artesano_id()
  ))
  with check (
    exists (
      select 1 from public.productos p
      where p.id = producto_variantes.producto_id
        and p.artesano_id = public.mi_artesano_id()
    )
    -- ANTI-IDOR (FK circular): la imagen de portada referenciada, si la hay, DEBE ser del
    -- MISMO producto (que ya se validó como del vendedor). Cierra el mass-assignment de
    -- imagen_variante_id apuntando a la imagen de otro artesano vía PostgREST directo.
    and (
      imagen_variante_id is null
      or exists (
        select 1 from public.producto_imagenes pi
        where pi.id = producto_variantes.imagen_variante_id
          and pi.producto_id = producto_variantes.producto_id
      )
    )
  );

-- ── D.2  inventario (espejo de la variante padre) ──
drop policy if exists inventario_public_select on public.inventario;
create policy inventario_public_select on public.inventario
  for select to anon, authenticated
  using (exists (
    select 1 from public.producto_variantes pv
    join public.productos p on p.id = pv.producto_id
    where pv.id = inventario.variante_id and p.status = 'publicado'
  ));

drop policy if exists inventario_admin_all on public.inventario;
create policy inventario_admin_all on public.inventario
  for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists inventario_vendedor_all on public.inventario;
create policy inventario_vendedor_all on public.inventario
  for all to authenticated
  using (exists (
    select 1 from public.producto_variantes pv
    join public.productos p on p.id = pv.producto_id
    where pv.id = inventario.variante_id and p.artesano_id = public.mi_artesano_id()
  ))
  with check (exists (
    select 1 from public.producto_variantes pv
    join public.productos p on p.id = pv.producto_id
    where pv.id = inventario.variante_id and p.artesano_id = public.mi_artesano_id()
  ));

-- ── D.3  producto_imagenes (espejo del producto padre) ──
drop policy if exists producto_imagenes_public_select on public.producto_imagenes;
create policy producto_imagenes_public_select on public.producto_imagenes
  for select to anon, authenticated
  using (exists (
    select 1 from public.productos p
    where p.id = producto_imagenes.producto_id and p.status = 'publicado'
  ));

drop policy if exists producto_imagenes_admin_all on public.producto_imagenes;
create policy producto_imagenes_admin_all on public.producto_imagenes
  for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists producto_imagenes_vendedor_all on public.producto_imagenes;
create policy producto_imagenes_vendedor_all on public.producto_imagenes
  for all to authenticated
  using (exists (
    select 1 from public.productos p
    where p.id = producto_imagenes.producto_id
      and p.artesano_id = public.mi_artesano_id()
  ))
  with check (
    exists (
      select 1 from public.productos p
      where p.id = producto_imagenes.producto_id
        and p.artesano_id = public.mi_artesano_id()
    )
    -- ANTI-IDOR (FK circular): la variante referenciada, si la hay, DEBE ser del MISMO
    -- producto (ya validado como del vendedor). Cierra el mass-assignment de variante_id
    -- apuntando a la variante de otro artesano vía PostgREST directo.
    and (
      variante_id is null
      or exists (
        select 1 from public.producto_variantes pv
        where pv.id = producto_imagenes.variante_id
          and pv.producto_id = producto_imagenes.producto_id
      )
    )
  );

-- ── D.4  Superficie mínima de funciones nuevas (patrón 0006/0008) ──
-- Los triggers corren como owner (SECURITY DEFINER); las policies evalúan las funciones a
-- nivel del sistema. Nadie las invoca vía API → se revoca EXECUTE por nombre (el gotcha
-- Supabase: los default-privileges conceden EXECUTE directo a anon/authenticated al crear,
-- y `revoke from public` NO basta).
revoke execute on function public.uuid_nil()     from anon, authenticated, public;
revoke execute on function public.opciones_norm(jsonb) from anon, authenticated, public;

-- ════════════════════════════════════════════════════════════════════════════
-- PARTE E — BACKFILL (idempotente; el respaldo son los constraints, no la lógica de app)
-- ════════════════════════════════════════════════════════════════════════════
-- Re-ejecutable sin duplicar gracias a: UNIQUE(producto_id,sku), PK inventario.variante_id,
-- y el índice parcial de portada. Cada paso usa on conflict do nothing / where not exists.

-- E.1  valor_declarado_centavos := precio_centavos donde esté vacío.
update public.productos
set valor_declarado_centavos = precio_centavos
where valor_declarado_centavos is null;

-- E.2  Heurística oficio → categoría (best-effort; el admin revisa después). Solo llena
-- categoria_id si está NULL y el oficio hace match. NO exige NOT NULL (borradores/publicados
-- quedan válidos hasta revisión gracias al CHECK condicional NOT VALID).
update public.productos p
set categoria_id = c.id
from public.categorias c
where p.categoria_id is null
  and c.slug = case
    when p.oficio ~* 'cer[aá]mica|barro|talavera|alfarer'         then 'ceramica-y-barro'
    when p.oficio ~* 'madera|alebrij|talla|copal'                 then 'talla-madera-y-alebrijes'
    when p.oficio ~* 'textil|bordad|telar|rebozo|huipil|ropa|tejid' then 'textil-y-ropa'
    when p.oficio ~* 'cobija|manta|tapete|cojin|hogar'            then 'textil-hogar'
    when p.oficio ~* 'palma|cester|fibra|mimbre|carrizo|ixtle'    then 'fibras-y-cesteria'
    when p.oficio ~* 'joyer|plata|plater|filigrana|orfebr'        then 'joyeria-y-plateria'
    else null
  end;

-- E.3  Variante DEFAULT por producto: opciones={}, sku=<id>||'-U', delta=0, activa=true.
-- El artesano nunca ve "variante" para piezas únicas: es infraestructura. Idempotente por
-- UNIQUE(producto_id, sku). Solo crea la default si el producto AÚN no tiene ninguna variante.
insert into public.producto_variantes (producto_id, sku, opciones, precio_delta_centavos, activa)
select p.id, p.id || '-U', '{}'::jsonb, 0, true
from public.productos p
where not exists (
  select 1 from public.producto_variantes pv where pv.producto_id = p.id
)
on conflict (producto_id, sku) do nothing;

-- E.4  Fila de inventario 1:1 por variante default. stock=1 para 'unico' (pieza única);
-- 0 en otros tipos (el artesano lo captura). Idempotente por PK variante_id.
insert into public.inventario (variante_id, stock)
select pv.id,
       case when p.tipo_producto = 'unico' then 1 else 0 end
from public.producto_variantes pv
join public.productos p on p.id = pv.producto_id
where pv.sku = p.id || '-U'
  and not exists (select 1 from public.inventario i where i.variante_id = pv.id)
on conflict (variante_id) do nothing;

-- E.5  Portada: productos.imagen (URL absoluta) → producto_imagenes (storage_path RELATIVO).
-- Convierte con la misma marca que pathDesdeUrl() del app ('/object/public/piezas/'). Solo
-- para productos con imagen que aún no tengan portada general registrada. es_principal=true,
-- variante_id NULL, orden 0, alt autollenado '<nombre>, <oficio> de <region>'.
-- IDEMPOTENTE: el índice parcial producto_imagenes_portada_general_unq impide duplicar la
-- portada; el where not exists evita reinsertar en re-ejecuciones.
insert into public.producto_imagenes (producto_id, variante_id, storage_path, alt, orden, es_principal)
select
  p.id,
  null,
  -- URL absoluta → path relativo tras '/object/public/piezas/'. Si por alguna razón la
  -- imagen ya fuera un path relativo (sin la marca), split_part devuelve el original.
  case
    when position('/object/public/piezas/' in p.imagen) > 0
      then split_part(p.imagen, '/object/public/piezas/', 2)
    else p.imagen
  end,
  p.nombre || ', ' || p.oficio || ' de ' || p.region,
  0,
  true
from public.productos p
where p.imagen is not null
  and p.imagen <> ''
  and not exists (
    select 1 from public.producto_imagenes pi
    where pi.producto_id = p.id and pi.es_principal and pi.variante_id is null
  );

-- ════════════════════════════════════════════════════════════════════════════
-- PARTE F — VISTA DE COMPATIBILIDAD public.productos_storefront
-- ════════════════════════════════════════════════════════════════════════════
-- SECURITY INVOKER: respeta la RLS del llamante (anon ve solo publicados por
-- productos_publicados_select de 0001). Reproduce EXACTO las 11 columnas que hoy consume
-- apps/web/src/lib/catalog.ts y AÑADE dos derivadas:
--   precio_desde   = precio_centavos + MIN(precio_delta_centavos) sobre variantes ACTIVAS.
--   disponible_total = SUM(inventario.disponible) sobre variantes ACTIVAS.
-- precio_desde es SOLO lectura de catálogo; NUNCA autoridad de cobro (eso se recalcula en
-- servidor por variante). El switch de catalog.ts de 'productos' a esta vista es un cambio
-- de código SEPARADO; el fallback estático (staticProducts) queda intacto ⇒ cero downtime.
--
-- security_invoker requiere PG15+ (Supabase lo cumple). Recrear con or replace es idempotente.
create or replace view public.productos_storefront
with (security_invoker = true) as
select
  p.id,
  p.nombre,
  p.maker,
  p.oficio,
  p.region,
  p.precio_centavos,
  p.imagen,
  p.descripcion,
  p.tecnica,
  p.materiales,
  p.medidas,
  p.precio_centavos + coalesce(
    (select min(pv.precio_delta_centavos)
       from public.producto_variantes pv
      where pv.producto_id = p.id and pv.activa = true),
    0
  ) as precio_desde,
  coalesce(
    (select sum(i.disponible)
       from public.producto_variantes pv
       join public.inventario i on i.variante_id = pv.id
      where pv.producto_id = p.id and pv.activa = true),
    0
  ) as disponible_total
from public.productos p;

grant select on public.productos_storefront to anon, authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- NOTAS PARA REVISIÓN HUMANA (no ejecutables)
-- ════════════════════════════════════════════════════════════════════════════
-- 1. NO APLICAR sin revisar: cae bajo el gate "preguntar antes de cambiar RLS/triggers de
--    status". Los triggers C.3 (sync portada) y C.4 (status agotado) escriben en productos.
-- 2. sync_portada_producto usa current_setting('app.supabase_public_url', true) para el host
--    del bucket. Si NO se setea ese GUC, la portada legado queda como ruta RELATIVA
--    '/storage/v1/object/public/piezas/<path>' (la app puede resolver el host). Para URL
--    absoluta, setear a nivel proyecto:  ALTER DATABASE <db> SET app.supabase_public_url = '<url>';
--    Alternativa Fase 2: dejar de sincronizar imagen y leer storage_path directo.
-- 3. FISCAL 2026 (fuera del scope de esta migración): las tasas del CLAUDE.md (~10.5%/~36%)
--    están desfasadas (reforma Art.113-A LISR: 2.5% ISR con RFC / 20% sin; IVA 8%/16%). NO se
--    hardcodean tasas aquí; se validan con contador en la fase de pagos.
-- 4. AUTORIDAD DE PRECIO: el precio efectivo SIEMPRE se recalcula en servidor
--    (precio_centavos + precio_delta_centavos). precio_desde de la vista es catálogo, no cobro.
