-- 0029 — Órdenes, ítems y payouts (checkout + reparto de ingresos)
-- Modelo Connect: separate charges & transfers. La PLATAFORMA cobra al comprador (PaymentIntent)
-- y luego TRANSFIERE a cada artesano su neto (su subtotal − comisión de plataforma). La comisión
-- se descuenta del artesano (el comprador paga el precio de lista). Retenciones fiscales/CFDI:
-- DIFERIDAS (se resolverán con contador). Idempotencia: UNIQUE(stripe_payment_intent_id) y
-- UNIQUE(order_id, artesano_id) para no pagar dos veces.

-- ── Órdenes ──
create table if not exists public.orders (
  id text primary key,                       -- generado por el backend (ord_<uuid>)
  comprador_id uuid references auth.users(id) on delete set null,
  email text,
  subtotal_centavos int not null,            -- lo que paga el comprador (suma de ítems)
  comision_centavos int not null,            -- lo que retiene la plataforma
  total_centavos int not null,               -- = subtotal (envío/impuestos futuros)
  moneda text not null default 'MXN',
  status text not null default 'pendiente',  -- pendiente | pagada | fallida
  stripe_payment_intent_id text unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ── Ítems de la orden (snapshot: precio y datos al momento de comprar) ──
create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id text not null references public.orders(id) on delete cascade,
  producto_id text,
  variante_id uuid,
  artesano_id uuid references public.artesanos(id) on delete set null,
  nombre text not null,
  opciones jsonb not null default '{}',
  cantidad int not null check (cantidad > 0),
  precio_centavos int not null,              -- unitario
  subtotal_centavos int not null             -- precio * cantidad
);
create index if not exists order_items_order_idx on public.order_items(order_id);
create index if not exists order_items_artesano_idx on public.order_items(artesano_id);

-- ── Payouts (transferencia a cada artesano; 1 por (orden, artesano)) ──
create table if not exists public.payouts (
  id uuid primary key default gen_random_uuid(),
  order_id text not null references public.orders(id) on delete cascade,
  artesano_id uuid references public.artesanos(id) on delete set null,
  bruto_centavos int not null,               -- subtotal de los ítems de ese artesano
  comision_centavos int not null,            -- comisión de plataforma sobre ese bruto
  neto_centavos int not null,                -- lo que recibe el artesano
  stripe_transfer_id text,
  status text not null default 'pendiente',  -- pendiente | transferido | sin_cuenta | fallido
  created_at timestamptz not null default now(),
  unique (order_id, artesano_id)
);
create index if not exists payouts_artesano_idx on public.payouts(artesano_id);

-- ── RLS ──
-- Comprador ve SUS órdenes/ítems. Artesano ve los ítems/payouts de LO SUYO. Escritura: solo
-- backend (service_role, bypassa RLS). anon: nada.
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.payouts enable row level security;

drop policy if exists orders_self on public.orders;
create policy orders_self on public.orders for select to authenticated
  using (comprador_id = auth.uid());

drop policy if exists order_items_comprador on public.order_items;
create policy order_items_comprador on public.order_items for select to authenticated
  using (order_id in (select id from public.orders where comprador_id = auth.uid()));

drop policy if exists order_items_artesano on public.order_items;
create policy order_items_artesano on public.order_items for select to authenticated
  using (artesano_id in (select id from public.artesanos where user_id = auth.uid()));

drop policy if exists payouts_artesano on public.payouts;
create policy payouts_artesano on public.payouts for select to authenticated
  using (artesano_id in (select id from public.artesanos where user_id = auth.uid()));

revoke all on public.orders from anon;
revoke all on public.order_items from anon;
revoke all on public.payouts from anon;
grant select on public.orders to authenticated;
grant select on public.order_items to authenticated;
grant select on public.payouts to authenticated;

-- ── Decremento ATÓMICO de inventario (anti-sobreventa). Solo baja si hay stock suficiente. ──
create or replace function public.decrementar_stock(p_variante uuid, p_qty int)
returns boolean language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  update public.inventario set stock = stock - p_qty, updated_at = now()
    where variante_id = p_variante and stock >= p_qty;
  get diagnostics n = row_count;
  return n > 0;
end;
$$;
revoke all on function public.decrementar_stock(uuid, int) from public, anon, authenticated;
grant execute on function public.decrementar_stock(uuid, int) to service_role;
