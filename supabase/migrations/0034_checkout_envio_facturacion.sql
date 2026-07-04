-- 0034 — Checkout completo: snapshot de envío + facturación en la orden, y perfil de facturación.
-- El comprador elige dirección (ya existe la tabla direcciones) y opcionalmente pide factura. La
-- dirección y los datos fiscales se CONGELAN en la orden al momento de comprar (snapshot: si luego
-- edita/borra su dirección, la orden conserva a dónde se envió). RFC/datos fiscales son SENSIBLES:
-- viven en facturacion_perfiles con RLS self, y el snapshot en orders queda protegido por la RLS de
-- orders (comprador ve solo lo suyo; el artesano ve order_items, NO orders → no ve el RFC).
--
-- CFDI (emisión vía PAC) sigue DIFERIDO: aquí solo se CAPTURA la solicitud (requiere_factura) y los
-- datos. La emisión real es un paso backend posterior (módulo tax).

-- ── Snapshot en la orden ──
alter table public.orders
  add column if not exists direccion_envio jsonb,               -- {destinatario,telefono,calle,colonia,ciudad,estado,cp,referencias}
  add column if not exists facturacion jsonb,                   -- {rfc,razon_social,regimen_fiscal,uso_cfdi,cp_fiscal,email}
  add column if not exists requiere_factura boolean not null default false,
  add column if not exists envio_centavos int not null default 0;  -- 0 por ahora (motor de envíos = fase posterior)

-- ── Perfil de facturación del comprador (uno por usuario; se reusa entre compras) ──
create table if not exists public.facturacion_perfiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  rfc text,                       -- SENSIBLE
  razon_social text,
  regimen_fiscal text,            -- clave SAT (ej. '612', '626')
  uso_cfdi text,                  -- clave SAT (ej. 'G03', 'S01')
  cp_fiscal text,
  email text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.facturacion_perfiles enable row level security;

-- Solo el dueño lee/escribe su perfil fiscal. El backend (service_role) bypassa RLS para snapshot.
drop policy if exists facturacion_self_all on public.facturacion_perfiles;
create policy facturacion_self_all on public.facturacion_perfiles for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

revoke all on public.facturacion_perfiles from anon;
grant select, insert, update, delete on public.facturacion_perfiles to authenticated;

-- touch_updated_at ya existe (lo usa direcciones); reusarlo.
drop trigger if exists facturacion_touch_updated_at on public.facturacion_perfiles;
create trigger facturacion_touch_updated_at before update on public.facturacion_perfiles
  for each row execute function public.touch_updated_at();
