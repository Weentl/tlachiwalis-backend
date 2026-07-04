-- 0006_surface_lockdown.sql — Reduce la superficie de la API (defensa en
-- profundidad SOBRE la RLS, que ya bloquea todo). Quita grants/execute que el
-- app no usa y que solo amplían lo que un atacante puede tocar. Idempotente.

-- 1) Tabla `admins`: NADA la consume vía API (el app usa is_admin() rpc; el
--    primer admin se siembra por psql). Se le quitan los grants por defecto de
--    Supabase para que ni siquiera aparezca en la superficie de PostgREST.
revoke all on public.admins from anon, authenticated;

-- 2) Tabla base `artesanos`: el público lee la VISTA artesanos_publicos (corre
--    como owner, no necesita grant en la base). Anon nunca debe tocar la base
--    (rfc/clabe). El admin es `authenticated`, conserva sus grants.
revoke all on public.artesanos from anon;

-- 3) Funciones: solo el admin autenticado debe poder invocarlas. Las policies
--    RLS evalúan is_admin() a nivel del sistema sin requerir execute al rol
--    llamante, y los triggers corren como owner; por eso revocar es seguro.
revoke execute on function public.is_admin() from anon;
revoke execute on function public.eliminar_artesano_seguro(uuid) from anon;
revoke execute on function public.touch_updated_at() from anon, authenticated, public;

-- NOTA: productos conserva SELECT para anon (el storefront lee piezas publicadas),
-- y artesanos/eliminar_artesano_seguro/is_admin conservan acceso para
-- `authenticated` (el panel admin). Todo lo demás sigue gobernado por RLS.
