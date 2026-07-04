-- 0030 — El admin puede LEER órdenes/ítems/payouts (dashboard con datos reales)
-- Las políticas de 0029 solo dejan al comprador ver lo suyo y al artesano lo suyo. El admin
-- necesita leer todo para el panel. is_admin() ya existe (verifica public.admins). Solo SELECT.

drop policy if exists orders_admin on public.orders;
create policy orders_admin on public.orders for select to authenticated using (public.is_admin());

drop policy if exists order_items_admin on public.order_items;
create policy order_items_admin on public.order_items for select to authenticated using (public.is_admin());

drop policy if exists payouts_admin on public.payouts;
create policy payouts_admin on public.payouts for select to authenticated using (public.is_admin());
