-- supabase/migrations/0003_storage_piezas.sql
-- Bucket de imagenes de producto: lectura publica, escritura SOLO admin.
-- Requiere is_admin() de 0002. Idempotente.

-- Bucket publico de lectura (sirve por /storage/v1/object/public/piezas/...).
insert into storage.buckets (id, name, public)
values ('piezas', 'piezas', true)
on conflict (id) do nothing;

-- storage.objects ya tiene RLS habilitado en Supabase.

-- Lectura: explicita por consistencia de API (listar/metadata). La ruta /object/public
-- ya es publica por el flag del bucket, pero esta policy no estorba.
drop policy if exists piezas_public_read on storage.objects;
create policy piezas_public_read on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'piezas');

-- Escritura: SOLO admin.
drop policy if exists piezas_admin_insert on storage.objects;
create policy piezas_admin_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'piezas' and public.is_admin());

drop policy if exists piezas_admin_update on storage.objects;
create policy piezas_admin_update on storage.objects
  for update to authenticated
  using (bucket_id = 'piezas' and public.is_admin())
  with check (bucket_id = 'piezas' and public.is_admin());

drop policy if exists piezas_admin_delete on storage.objects;
create policy piezas_admin_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'piezas' and public.is_admin());

-- ADVERTENCIA: el bucket es PUBLICO. No subir aqui documentos fiscales ni nada
-- sensible. Los datos fiscales (rfc/regimen_fiscal/clabe) viven en columnas de
-- public.artesanos protegidas por RLS, NUNCA como archivos en este bucket.
