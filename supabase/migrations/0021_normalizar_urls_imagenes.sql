-- 0021_normalizar_urls_imagenes.sql — imágenes SAME-ORIGIN. Normaliza cualquier URL de imagen
-- ABSOLUTA (con host de Supabase) a RELATIVA `/storage/...`, para que pase por el rewrite de
-- next.config (host-portable; el navegador nunca depende de alcanzar el host de Supabase).
-- Idempotente: sólo toca las que empiezan con http(s)://host/storage/.
update public.artesanos
   set foto_url = regexp_replace(foto_url, '^https?://[^/]+(/storage/)', '\1')
 where foto_url ~ '^https?://[^/]+/storage/';

update public.artesanos
   set foto_portada = regexp_replace(foto_portada, '^https?://[^/]+(/storage/)', '\1')
 where foto_portada ~ '^https?://[^/]+/storage/';

update public.productos
   set imagen = regexp_replace(imagen, '^https?://[^/]+(/storage/)', '\1')
 where imagen ~ '^https?://[^/]+/storage/';
