-- 0024 — Consentimiento de marketing (LFPDPPP)
-- Registro mínimo + progresivo: el consentimiento de MARKETING es SEPARADO y NO premarcado
-- (distinto de aceptar Aviso/Términos). Guardamos evidencia: bandera + timestamp.
-- Derecho ARCO de Oposición: el comprador puede activarlo/desactivarlo en "Mi cuenta" (F5).

alter table public.perfiles
  add column if not exists marketing_consent boolean not null default false,
  add column if not exists marketing_consent_at timestamptz;

-- handle_new_user: además de nombre/telefono/avatar, captura el consentimiento de marketing
-- que viene en user_metadata (lo pasa /buyers/register). search_path='' → todo calificado.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  mkt boolean := coalesce((new.raw_user_meta_data->>'marketing_consent')::boolean, false);
begin
  insert into public.perfiles (
    user_id, nombre, telefono, avatar_url, marketing_consent, marketing_consent_at
  )
  values (
    new.id,
    coalesce(
      new.raw_user_meta_data->>'nombre',
      new.raw_user_meta_data->>'full_name',
      new.raw_user_meta_data->>'name'
    ),
    new.raw_user_meta_data->>'telefono',
    new.raw_user_meta_data->>'avatar_url',
    mkt,
    case when mkt then now() else null end
  )
  on conflict (user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
