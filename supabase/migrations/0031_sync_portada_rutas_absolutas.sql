-- 0031 — sync_portada_producto: dejar pasar rutas ABSOLUTAS (fix imágenes demo)
-- El trigger derivaba productos.imagen = '/storage/v1/object/public/piezas/' || storage_path.
-- Si storage_path ya es absoluto (http(s):// o /… — p.ej. /images/… del /public en demos, o
-- /storage/… legado), prefijarlo lo rompe (doble prefijo). Ahora se usa tal cual, igual que
-- urlPublicaPieza en el frontend. Solo las LLAVES relativas del bucket reciben el prefijo.

create or replace function public.sync_portada_producto()
returns trigger language plpgsql security definer set search_path to '' as $function$
declare
  v_producto text;
  v_path text;
  v_base text;
  v_url text;
begin
  v_producto := coalesce(new.producto_id, old.producto_id);

  select storage_path into v_path
  from public.producto_imagenes
  where producto_id = v_producto
    and es_principal
    and variante_id is null
  limit 1;

  if v_path is null then
    return coalesce(new, old); -- sin portada general: no pisar el legado
  end if;

  if v_path ~ '^https?://' or left(v_path, 1) = '/' then
    -- Ruta absoluta (http, /storage/… o /images/…): úsala tal cual.
    v_url := v_path;
  else
    v_base := current_setting('app.supabase_public_url', true);
    if v_base is null or v_base = '' then
      v_url := '/storage/v1/object/public/piezas/' || v_path;
    else
      v_url := rtrim(v_base, '/') || '/storage/v1/object/public/piezas/' || v_path;
    end if;
  end if;

  update public.productos set imagen = v_url where id = v_producto and imagen is distinct from v_url;
  return coalesce(new, old);
end;
$function$;
