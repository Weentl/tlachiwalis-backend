-- 0035 — Motor de envíos (MVP): tarifa por ZONA (nacional / extendida) + PESO, resuelta por código
-- postal de destino. Grounded en cómo operan las paqueterías MX: las "zonas extendidas" (sierra /
-- difícil acceso) se identifican por CP, se visitan cada 7–10 días hábiles, cobran cargo adicional y
-- pueden entregarse en sucursal (ocurre). NO bloqueamos la venta a la sierra: cobramos el extra, ETA
-- más largo y avisamos que se coordina. Fuente para reemplazar el seed por la lista oficial del
-- courier / API Skydropx más adelante.
--
-- AUTORIDAD: el costo lo calcula SIEMPRE el backend (service_role) desde estas tablas; el cliente
-- nunca fija el monto de envío (igual que precios). Por eso RLS niega a anon/authenticated: solo el
-- backend lee. El envío se queda en la PLATAFORMA (merchant of record); no se dispersa al artesano.

-- ── Zonas + tarifas ──
create table if not exists public.envio_zonas (
  clave text primary key,                    -- 'nacional' | 'extendida'
  nombre text not null,
  tarifa_base_centavos int not null,         -- hasta 1 kg
  tarifa_kg_extra_centavos int not null,     -- por cada kg adicional (redondeo hacia arriba)
  dias_min int not null,
  dias_max int not null,
  requiere_coordinacion boolean not null default false,  -- true en extendida (ocurre / contacto)
  nota text,
  activa boolean not null default true
);

insert into public.envio_zonas (clave, nombre, tarifa_base_centavos, tarifa_kg_extra_centavos, dias_min, dias_max, requiere_coordinacion, nota)
values
  ('nacional',  'Envío nacional',              9900,  3500, 3,  6,  false, null),
  ('extendida', 'Zona extendida (difícil acceso)', 18900, 6000, 8, 14, true,
    'Tu CP es zona de cobertura extendida (sierra / difícil acceso): la paquetería la visita cada 7–14 días hábiles. Podemos entregar en sucursal (ocurre); te contactamos para coordinar.')
on conflict (clave) do update set
  nombre = excluded.nombre,
  tarifa_base_centavos = excluded.tarifa_base_centavos,
  tarifa_kg_extra_centavos = excluded.tarifa_kg_extra_centavos,
  dias_min = excluded.dias_min,
  dias_max = excluded.dias_max,
  requiere_coordinacion = excluded.requiere_coordinacion,
  nota = excluded.nota;

-- ── CPs de zona extendida (por PREFIJO). Set inicial ilustrativo, anclado en regiones de sierra
-- reales; en producción se reemplaza por la lista oficial del courier. Match: cp LIKE prefijo%. ──
create table if not exists public.envio_cp_extendido (
  prefijo text primary key,                  -- 2–5 dígitos; el CP de destino que empiece con esto
  nombre text not null,
  estado text
);

insert into public.envio_cp_extendido (prefijo, nombre, estado) values
  ('331', 'Sierra Tarahumara (Guachochi/Creel)', 'Chihuahua'),
  ('332', 'Sierra Tarahumara', 'Chihuahua'),
  ('333', 'Sierra Tarahumara', 'Chihuahua'),
  ('334', 'Sierra Tarahumara (Batopilas)', 'Chihuahua'),
  ('413', 'La Montaña (Tlapa)', 'Guerrero'),
  ('439', 'Cuautepec de Hinojosa', 'Hidalgo'),
  ('684', 'Sierra Juárez', 'Oaxaca'),
  ('685', 'Sierra Norte', 'Oaxaca'),
  ('731', 'Sierra Norte (Huauchinango)', 'Puebla'),
  ('733', 'Sierra Norte (Zacatlán)', 'Puebla'),
  ('785', 'Charcas', 'San Luis Potosí'),
  ('843', 'Santa Ana', 'Sonora'),
  ('862', 'Nacajuca', 'Tabasco'),
  ('298', 'Los Altos / Selva', 'Chiapas')
on conflict (prefijo) do update set nombre = excluded.nombre, estado = excluded.estado;

-- ── Config (una fila): peso por omisión cuando el producto no trae peso, y umbral de envío gratis. ──
create table if not exists public.envio_config (
  id int primary key default 1 check (id = 1),
  peso_default_gramos int not null default 800,
  umbral_gratis_centavos int,                -- null = sin envío gratis; si el subtotal ≥ esto, envío = 0
  activo boolean not null default true
);
insert into public.envio_config (id, peso_default_gramos, umbral_gratis_centavos, activo)
values (1, 800, null, true)
on conflict (id) do nothing;

-- ── RLS: datos de referencia solo para el backend (service_role bypassa RLS). anon/authenticated: nada. ──
alter table public.envio_zonas enable row level security;
alter table public.envio_cp_extendido enable row level security;
alter table public.envio_config enable row level security;
revoke all on public.envio_zonas from anon, authenticated;
revoke all on public.envio_cp_extendido from anon, authenticated;
revoke all on public.envio_config from anon, authenticated;

-- ── Pesos de los productos demo (estaban en null → el motor usaría el default; los hacemos realistas). ──
update public.productos set peso_gramos = 300  where id = 'demo-blusa'  and peso_gramos is null;
update public.productos set peso_gramos = 500  where id = 'demo-huipil' and peso_gramos is null;
update public.productos set peso_gramos = 2500 where id = 'demo-tapete' and peso_gramos is null;
update public.productos set peso_gramos = 600  where id = 'demo-taza'   and peso_gramos is null;
update public.productos set peso_gramos = 1800 where id = 'demo-vasija' and peso_gramos is null;
update public.productos set peso_gramos = 900  where id like 'tal-%'    and peso_gramos is null;
