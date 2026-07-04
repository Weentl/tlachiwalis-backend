-- 0007_taxonomia.sql — FASE 0: taxonomía de producto (categorías + atributos).
-- Cimiento del catálogo evolucionado (ver docs/MODELO_PRODUCTO.md). Idempotente.
-- NO toca la tabla `productos` todavía (eso es Fase 1). NO mueve dinero.

-- ── slugify en BD: el admin/artesano NUNCA teclea slugs; se generan del nombre ──
create or replace function public.slugify(txt text)
returns text
language sql
immutable
as $$
  select coalesce(nullif(
    trim(both '-' from regexp_replace(
      lower(translate(coalesce(txt, ''),
        'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunAEIOUUN')),
      '[^a-z0-9]+', '-', 'g')),
    ''), 'item');
$$;

-- ============================ TABLAS ============================
create table if not exists public.categorias (
  id smallint generated always as identity primary key,
  slug text unique not null,
  nombre text not null,
  parent_id smallint references public.categorias (id) on delete set null,
  clave_prod_serv text,                       -- SAT c_ClaveProdServ (UNSPSC) — curable por admin, para CFDI futuro
  clave_unidad text not null default 'H87',   -- H87 = Pieza
  objeto_impuesto text not null default '02',
  orden smallint not null default 0,
  activa boolean not null default true,
  created_at timestamptz not null default now()
);

-- Autogenera el slug del nombre si no viene.
create or replace function public.categorias_slug()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.slug is null or new.slug = '' then
    new.slug := public.slugify(new.nombre);
  end if;
  return new;
end;
$$;
drop trigger if exists categorias_slug_trg on public.categorias;
create trigger categorias_slug_trg
  before insert or update on public.categorias
  for each row execute function public.categorias_slug();

create table if not exists public.atributos (
  id smallint generated always as identity primary key,
  codigo text unique not null,                -- 'talla','color','material','diametro_cm'
  nombre text not null,                        -- etiqueta visible
  tipo text not null check (tipo in ('lista', 'texto', 'numero', 'booleano')),
  unidad text,                                 -- 'cm','g','ml'
  filtrable boolean not null default false,
  ayuda_texto text
);

create table if not exists public.atributo_opciones (
  id int generated always as identity primary key,
  atributo_id smallint not null references public.atributos (id) on delete cascade,
  valor text not null,
  etiqueta text not null,                      -- lenguaje amable ('Mediana (M)')
  hex text,                                    -- swatch para colores
  orden smallint not null default 0,
  unique (atributo_id, valor)
);

-- El "formulario dinámico" del wizard SALE de esta tabla:
create table if not exists public.categoria_atributos (
  categoria_id smallint not null references public.categorias (id) on delete cascade,
  atributo_id smallint not null references public.atributos (id) on delete cascade,
  es_variacion boolean not null default false, -- eje de variante (talla/color)
  requerido boolean not null default false,
  orden smallint not null default 0,
  primary key (categoria_id, atributo_id)
);

-- ============================ RLS ============================
-- El catálogo NO es sensible: lectura pública (storefront filtra + el form lo lee);
-- escritura solo admin (patrón is_admin() de 0002).
alter table public.categorias enable row level security;
alter table public.atributos enable row level security;
alter table public.atributo_opciones enable row level security;
alter table public.categoria_atributos enable row level security;

do $$
declare t text;
begin
  foreach t in array array['categorias','atributos','atributo_opciones','categoria_atributos'] loop
    execute format('drop policy if exists %I on public.%I', t||'_read', t);
    execute format('create policy %I on public.%I for select to anon, authenticated using (true)', t||'_read', t);
    execute format('drop policy if exists %I on public.%I', t||'_write', t);
    execute format('create policy %I on public.%I for all to authenticated using (public.is_admin()) with check (public.is_admin())', t||'_write', t);
  end loop;
end $$;

-- ============================ SEED (familias núcleo) ============================
insert into public.categorias (slug, nombre, orden) values
  ('ceramica-y-barro',            'Cerámica y barro',            1),
  ('talla-madera-y-alebrijes',    'Talla en madera y alebrijes', 2),
  ('textil-y-ropa',               'Textil y ropa',               3),
  ('textil-hogar',                'Textil para el hogar',        4),
  ('fibras-y-cesteria',           'Fibras y cestería',           5),
  ('joyeria-y-plateria',          'Joyería y platería',          6)
on conflict (slug) do nothing;

insert into public.atributos (codigo, nombre, tipo, unidad, filtrable, ayuda_texto) values
  ('talla',          'Talla',           'lista',    null, true,  'Tallas disponibles de la prenda'),
  ('color',          'Color',           'lista',    null, true,  'Colores disponibles'),
  ('material',       'Material',        'lista',    null, true,  'De qué está hecho'),
  ('tecnica',        'Técnica',         'texto',    null, false, 'Técnica artesanal'),
  ('alto_cm',        'Alto',            'numero',   'cm', false, 'Aproximado está bien'),
  ('ancho_cm',       'Ancho',           'numero',   'cm', false, 'Aproximado está bien'),
  ('largo_cm',       'Largo',           'numero',   'cm', false, 'Aproximado está bien'),
  ('diametro_cm',    'Diámetro',        'numero',   'cm', false, 'Aproximado está bien'),
  ('peso_g',         'Peso',            'numero',   'g',  false, 'Peso aproximado con empaque'),
  ('apto_alimentos', 'Apto alimentos',  'booleano', null, true,  '¿Se puede usar para comer/beber?')
on conflict (codigo) do nothing;

-- Opciones de talla (letra MX) y una paleta base de color.
insert into public.atributo_opciones (atributo_id, valor, etiqueta, orden)
select a.id, v.valor, v.etiqueta, v.orden
from (values ('CH','Chica (CH)',1),('M','Mediana (M)',2),('G','Grande (G)',3),('EG','Extra grande (EG)',4)) as v(valor, etiqueta, orden)
join public.atributos a on a.codigo = 'talla'
on conflict (atributo_id, valor) do nothing;

insert into public.atributo_opciones (atributo_id, valor, etiqueta, hex, orden)
select a.id, v.valor, v.etiqueta, v.hex, v.orden
from (values
  ('negro','Negro','#222222',1),('blanco','Blanco','#f5f5f0',2),('rojo','Rojo','#a32929',3),
  ('azul','Azul','#2a4d7a',4),('verde','Verde','#3f6b47',5),('cafe','Café','#6b4a2b',6),
  ('amarillo','Amarillo','#d9a441',7),('multicolor','Multicolor',null,8)
) as v(valor, etiqueta, hex, orden)
join public.atributos a on a.codigo = 'color'
on conflict (atributo_id, valor) do nothing;

-- Qué atributos pide cada categoría (el formulario dinámico).
insert into public.categoria_atributos (categoria_id, atributo_id, es_variacion, requerido, orden)
select c.id, a.id, v.es_var, v.req, v.ord
from (values
  -- Cerámica y barro (pieza única; dimensiones + apto alimentos)
  ('ceramica-y-barro','diametro_cm', false, false, 1),
  ('ceramica-y-barro','alto_cm',     false, false, 2),
  ('ceramica-y-barro','tecnica',     false, false, 3),
  ('ceramica-y-barro','apto_alimentos', false, false, 4),
  -- Talla en madera (pieza única; dimensiones + material)
  ('talla-madera-y-alebrijes','largo_cm', false, false, 1),
  ('talla-madera-y-alebrijes','alto_cm',  false, false, 2),
  ('talla-madera-y-alebrijes','material', false, false, 3),
  ('talla-madera-y-alebrijes','tecnica',  false, false, 4),
  -- Textil y ropa (VARIANTES: talla + color)
  ('textil-y-ropa','talla',    true,  true,  1),
  ('textil-y-ropa','color',    true,  false, 2),
  ('textil-y-ropa','material', false, false, 3),
  ('textil-y-ropa','tecnica',  false, false, 4),
  -- Textil hogar (color variante; dimensiones)
  ('textil-hogar','largo_cm', false, false, 1),
  ('textil-hogar','ancho_cm', false, false, 2),
  ('textil-hogar','color',    true,  false, 3),
  ('textil-hogar','material', false, false, 4),
  -- Fibras y cestería (dimensiones; color si teñido)
  ('fibras-y-cesteria','alto_cm',   false, false, 1),
  ('fibras-y-cesteria','diametro_cm', false, false, 2),
  ('fibras-y-cesteria','material',  false, false, 3),
  ('fibras-y-cesteria','color',     true,  false, 4),
  -- Joyería (material; color de cuenta como variante)
  ('joyeria-y-plateria','material', false, true,  1),
  ('joyeria-y-plateria','color',    true,  false, 2),
  ('joyeria-y-plateria','largo_cm', false, false, 3)
) as v(cat_slug, atr_cod, es_var, req, ord)
join public.categorias c on c.slug = v.cat_slug
join public.atributos a on a.codigo = v.atr_cod
on conflict (categoria_id, atributo_id) do nothing;
