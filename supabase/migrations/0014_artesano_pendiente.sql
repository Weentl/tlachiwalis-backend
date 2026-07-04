-- 0014_artesano_pendiente.sql — estado 'pendiente' para la APROBACIÓN del admin.
-- Al terminar el registro autoguiado, el artesano queda 'pendiente' (NO puede acceder;
-- es_vendedor()/mi_artesano_id() de 0010 exigen 'activo'). El admin lo APRUEBA → 'activo'.
-- Estados: pendiente (registrado, en revisión) | activo (aprobado) | pausado (suspendido).
-- Idempotente.
alter table public.artesanos drop constraint if exists artesanos_status_check;
alter table public.artesanos
  add constraint artesanos_status_check
  check (status in ('activo', 'pausado', 'pendiente'));
