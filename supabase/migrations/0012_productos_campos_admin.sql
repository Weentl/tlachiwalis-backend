-- 0012_productos_campos_admin.sql — blinda columnas de OVERRIDE fiscal/envío a solo-admin.
-- Hallazgo del review de Fase 3 (severidad media): la RLS de vendedor sobre productos (0008)
-- solo restringe FILAS (artesano_id = mi_artesano_id()), NO columnas. Un vendedor que pegue
-- DIRECTO a PostgREST podría fijar clave_prod_serv (clasificación SAT) o valor_declarado_centavos
-- (valor fiscal/aduanal) a su antojo. El whitelist del Server Action protege la vía de la app,
-- pero NO la vía directa. Este trigger es el respaldo en BD: para NO-admin, fuerza valores seguros.
-- Idempotente. SECURITY DEFINER + search_path='' (patrón 0002/0008/0009).

create or replace function public.productos_forzar_campos_admin()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- El admin (panel) sí decide estos overrides; cualquier otro (vendedor, anon) no.
  if not public.is_admin() then
    new.clave_prod_serv := null;                          -- hereda de la categoría (0007)
    new.valor_declarado_centavos := new.precio_centavos;  -- server-derivado, no manipulable
  end if;
  return new;
end;
$$;

drop trigger if exists productos_forzar_campos_admin_trg on public.productos;
create trigger productos_forzar_campos_admin_trg
  before insert or update on public.productos
  for each row execute function public.productos_forzar_campos_admin();

revoke all on function public.productos_forzar_campos_admin() from public, anon, authenticated;
