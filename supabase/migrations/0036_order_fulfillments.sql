-- 0036 — Estados del pedido (fulfillment). Ciclo post-compra por (orden, artesano) — espeja los
-- payouts: en un carrito multi-artesano cada taller prepara y envía LO SUYO, con su propio estado y
-- guía. Máquina: por_validar → validado → enviado → entregado (o cancelado antes de enviar).
--
-- PRIVACIDAD: la fila trae un snapshot de la dirección de ENVÍO (para que el artesano sepa a dónde
-- mandar), NUNCA los datos de facturación/RFC (esos viven en orders, que el artesano no lee).
-- AUTORIDAD: las transiciones pasan por la RPC `avanzar_fulfillment` (SECURITY DEFINER con authz +
-- validación de la máquina de estados); no hay UPDATE directo del cliente.

create table if not exists public.order_fulfillments (
  id uuid primary key default gen_random_uuid(),
  order_id text not null references public.orders(id) on delete cascade,
  artesano_id uuid not null references public.artesanos(id) on delete cascade,
  estado text not null default 'por_validar'
    check (estado in ('por_validar','validado','enviado','entregado','cancelado')),
  direccion_envio jsonb,          -- snapshot SOLO de envío (sin facturación)
  paqueteria text,
  guia text,
  guia_url text,
  nota text,                      -- motivo de cancelación o comentario del taller
  validado_en timestamptz,
  enviado_en timestamptz,
  entregado_en timestamptz,
  cancelado_en timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (order_id, artesano_id)
);
create index if not exists fulfillments_order_idx on public.order_fulfillments(order_id);
create index if not exists fulfillments_artesano_idx on public.order_fulfillments(artesano_id);

drop trigger if exists fulfillments_touch_updated_at on public.order_fulfillments;
create trigger fulfillments_touch_updated_at before update on public.order_fulfillments
  for each row execute function public.touch_updated_at();

-- ── RLS ── comprador ve las de SUS órdenes; vendedor las de LO SUYO; admin todo. Escritura: solo RPC.
alter table public.order_fulfillments enable row level security;

drop policy if exists fulfillments_comprador on public.order_fulfillments;
create policy fulfillments_comprador on public.order_fulfillments for select to authenticated
  using (order_id in (select id from public.orders where comprador_id = auth.uid()));

drop policy if exists fulfillments_vendedor on public.order_fulfillments;
create policy fulfillments_vendedor on public.order_fulfillments for select to authenticated
  using (artesano_id in (select id from public.artesanos where user_id = auth.uid()));

drop policy if exists fulfillments_admin on public.order_fulfillments;
create policy fulfillments_admin on public.order_fulfillments for select to authenticated
  using (public.is_admin());

revoke all on public.order_fulfillments from anon, authenticated;
grant select on public.order_fulfillments to authenticated;

-- ── RPC: avanzar el estado (authz + máquina de estados). SECURITY DEFINER: hace su propia authz. ──
create or replace function public.avanzar_fulfillment(
  p_id uuid,
  p_estado text,
  p_paqueteria text default null,
  p_guia text default null,
  p_guia_url text default null,
  p_nota text default null
) returns public.order_fulfillments
language plpgsql security definer set search_path = '' as $$
declare
  f public.order_fulfillments;
  es_admin boolean := public.is_admin();
  es_dueno boolean;
  rank_actual int;
  rank_nuevo int;
begin
  select * into f from public.order_fulfillments where id = p_id for update;
  if not found then raise exception 'fulfillment_no_encontrado'; end if;

  -- Authz: admin, o dueño del artesano (activo). Nadie más (anti-IDOR).
  es_dueno := exists (
    select 1 from public.artesanos a
    where a.id = f.artesano_id and a.user_id = auth.uid() and a.status = 'activo'
  );
  if not (es_admin or es_dueno) then raise exception 'no_autorizado'; end if;

  -- Máquina de estados: rank creciente; cancelar solo antes de enviar; terminales no se mueven.
  rank_actual := case f.estado
    when 'por_validar' then 0 when 'validado' then 1 when 'enviado' then 2 when 'entregado' then 3 else -1 end;
  rank_nuevo := case p_estado
    when 'validado' then 1 when 'enviado' then 2 when 'entregado' then 3 when 'cancelado' then 9 else -99 end;

  if f.estado in ('entregado','cancelado') then raise exception 'estado_terminal'; end if;

  if p_estado = 'cancelado' then
    if f.estado not in ('por_validar','validado') then raise exception 'no_cancelable'; end if;
  elsif rank_nuevo <> rank_actual + 1 then
    raise exception 'transicion_invalida';   -- solo avanzar un paso a la vez
  end if;

  if p_estado = 'enviado' and coalesce(nullif(trim(p_guia), ''), null) is null then
    raise exception 'guia_requerida';
  end if;

  update public.order_fulfillments set
    estado = p_estado,
    paqueteria = case when p_estado = 'enviado' then nullif(trim(p_paqueteria), '') else paqueteria end,
    guia = case when p_estado = 'enviado' then nullif(trim(p_guia), '') else guia end,
    guia_url = case when p_estado = 'enviado' then nullif(trim(p_guia_url), '') else guia_url end,
    nota = coalesce(nullif(trim(p_nota), ''), nota),
    validado_en  = case when p_estado = 'validado'  then now() else validado_en end,
    enviado_en   = case when p_estado = 'enviado'   then now() else enviado_en end,
    entregado_en = case when p_estado = 'entregado' then now() else entregado_en end,
    cancelado_en = case when p_estado = 'cancelado' then now() else cancelado_en end
  where id = p_id
  returning * into f;

  return f;
end;
$$;

revoke all on function public.avanzar_fulfillment(uuid, text, text, text, text, text) from public, anon;
grant execute on function public.avanzar_fulfillment(uuid, text, text, text, text, text) to authenticated;

-- ── Backfill: órdenes YA pagadas → crea sus fulfillments (por artesano) para que aparezcan de una vez. ──
insert into public.order_fulfillments (order_id, artesano_id, direccion_envio)
select oi.order_id, oi.artesano_id, o.direccion_envio
from public.order_items oi
join public.orders o on o.id = oi.order_id
where o.status = 'pagada' and oi.artesano_id is not null
group by oi.order_id, oi.artesano_id, o.direccion_envio
on conflict (order_id, artesano_id) do nothing;
