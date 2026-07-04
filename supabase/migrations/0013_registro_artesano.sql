-- 0013_registro_artesano.sql — AUTO-REGISTRO del artesano.
-- Cambio de modelo: el ADMIN ya no captura datos; solo genera un LINK de invitación.
-- El artesano abre el link y llena TODO (nombre, cuenta, tipo de venta, página, cobros).
-- Los datos fiscales viven en STRIPE (Connect), no aquí (solo guardamos stripe_account_id).
-- Aditivo, idempotente, no destructivo (las tablas quedaron vacías por el reset previo).

-- ── Campos nuevos de artesano (los llena el artesano en el registro autoguiado) ──
alter table public.artesanos
  -- Nombre legal separado (formato MX). El display público sigue en `nombre`.
  add column if not exists nombres text,
  add column if not exists apellido_paterno text,
  add column if not exists apellido_materno text,           -- opcional
  add column if not exists fecha_nacimiento date,
  add column if not exists telefono text,                    -- WhatsApp/contacto
  -- Cómo vende: persona (independiente) | taller (con ayudantes) | tienda (comercio).
  add column if not exists tipo_vendedor text not null default 'persona',
  add column if not exists nombre_negocio text,              -- para taller/tienda
  add column if not exists num_personas smallint,            -- 1 = solo/a; >1 con equipo
  add column if not exists direccion jsonb,                  -- {calle,ciudad,estado,cp} opcional
  add column if not exists foto_portada text,                -- banner de su página pública
  add column if not exists redes jsonb,                      -- {instagram,facebook,web,...}
  add column if not exists envia_nacional boolean,           -- ¿envía a todo México? (Fase envío)
  add column if not exists anios_experiencia smallint,
  -- Cobros/fiscal: Stripe Connect es la autoridad; aquí solo el id de la cuenta.
  add column if not exists stripe_account_id text,
  add column if not exists onboarding_completo boolean not null default false;

-- tipo_vendedor: whitelist. La tabla está vacía → se valida de inmediato (sin NOT VALID).
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'artesanos_tipo_vendedor_check') then
    alter table public.artesanos
      add constraint artesanos_tipo_vendedor_check
      check (tipo_vendedor in ('persona', 'taller', 'tienda'));
  end if;
end $$;

create unique index if not exists artesanos_stripe_account_unique
  on public.artesanos (stripe_account_id) where stripe_account_id is not null;

-- ── Invitación de REGISTRO: ya NO requiere un artesano previo ──
-- Antes el admin creaba el artesano y luego invitaba. Ahora el admin solo genera el link;
-- el artesano se crea AL RECLAMAR (el servicio service_role lo inserta con los datos que
-- capturó el registro). Por eso artesano_id pasa a NULLABLE (NULL = invitación de registro
-- aún sin reclamar). Al reclamar se setea artesano_id + usado_en.
alter table public.invitaciones
  alter column artesano_id drop not null;

-- Opcional: distinguir el propósito del link (registro nuevo vs. segundo taller de un
-- artesano existente). 'registro' = crea artesano; 'taller' = liga a artesano_id existente.
alter table public.invitaciones
  add column if not exists proposito text not null default 'registro';
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'invitaciones_proposito_check') then
    alter table public.invitaciones
      add constraint invitaciones_proposito_check
      check (proposito in ('registro', 'taller'));
  end if;
end $$;
