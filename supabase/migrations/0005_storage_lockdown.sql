-- 0005_storage_lockdown.sql — Blinda el bucket 'piezas'. Idempotente.
-- Ejecutar tras 0003/0004.

-- 1) Quitar la lectura/listado por API a ANÓNIMOS.
--    El flag public=true del bucket sigue sirviendo los archivos por
--    /storage/v1/object/public/piezas/<path> (NO depende de esta policy), por lo
--    que las imágenes del storefront siguen cargando. Pero sin la policy, anon ya
--    NO puede ENUMERAR el bucket vía la API (storage.objects list()/select).
drop policy if exists piezas_public_read on storage.objects;

-- Lectura por API solo para administradores (el panel hoy no la usa, pero evita
-- exponer el listado completo a cualquiera).
drop policy if exists piezas_admin_select on storage.objects;
create policy piezas_admin_select on storage.objects
  for select to authenticated
  using (bucket_id = 'piezas' and public.is_admin());

-- 2) Límite de tamaño y tipos MIME a NIVEL de bucket (defensa más allá de la app).
--    Bloquea archivos > 5 MB y todo lo que no sea JPG/PNG/WebP (incl. SVG con
--    script), aunque alguien intente subir por la API saltándose la Server Action.
update storage.buckets
  set file_size_limit = 5242880, -- 5 MB
      allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']
  where id = 'piezas';
