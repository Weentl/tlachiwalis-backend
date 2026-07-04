-- 0020_fix_grants_variantes.sql — FIX: el rol `authenticated` (admin y vendedor) NO podía
-- crear/editar piezas ("No se pudo guardar la pieza. Revisa los datos e intenta de nuevo.").
--
-- Causa raíz: el índice único `producto_variantes_opciones_unq` evalúa `opciones_norm(opciones)`
-- en cada INSERT/UPDATE de `producto_variantes`, y esa evaluación necesita EXECUTE sobre
-- `opciones_norm(jsonb)` y `uuid_nil()`. El lockdown de permisos (0006) revocó EXECUTE en masa
-- (público/anon/authenticated) y no re-otorgó estas dos → Postgres lanzaba
-- "permission denied for function opciones_norm / uuid_nil" (42501), que el wizard mapeaba al
-- mensaje genérico. Como service_role SÍ las tenía, sólo fallaba desde el app (bajo RLS), no por
-- psql/superusuario.
--
-- Son funciones internas e inofensivas (normalizan las claves jsonb para el índice; uuid nil).
-- No tocan RLS ni exponen datos. Se otorga EXECUTE al rol de app.
grant execute on function public.opciones_norm(jsonb) to authenticated;
grant execute on function public.uuid_nil() to authenticated;
