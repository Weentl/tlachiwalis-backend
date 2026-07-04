-- 0016_invitacion_estado.sql — validación del link en CADA carga de /unirse.
-- Problema: la página del registro (anon) no podía saber si el token seguía válido (anon
-- no lee `invitaciones` por RLS), así que un link revocado/expirado seguía dejando entrar.
-- Solución: RPC que devuelve el ESTADO por hash del token. SECURITY DEFINER + search_path=''.
-- Sin oráculo útil: el hash requiere el token (no reversible); probar hashes al azar da
-- 'invalida'. Por eso se puede exponer a anon (a diferencia de invitacion_valida, que es
-- para el claim con service_role).
create or replace function public.registro_invitacion_estado(p_token_hash text)
returns text
language sql
security definer
set search_path = ''
stable
as $$
  select coalesce(
    (select case
       when i.revocada_en is not null then 'revocada'
       when i.usado_en is not null then 'usada'
       when i.expira_en <= now() then 'expirada'
       else 'valida'
     end
     from public.invitaciones i
     where i.token_hash = p_token_hash
     limit 1),
    'invalida'
  );
$$;

-- Exponer a anon/authenticated (la página del registro corre como anon). Revoca el resto.
revoke all on function public.registro_invitacion_estado(text) from public;
grant execute on function public.registro_invitacion_estado(text) to anon, authenticated;
