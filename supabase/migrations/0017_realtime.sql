-- 0017_realtime.sql — habilita Supabase Realtime en el flujo de aprobación.
-- La sala de espera se suscribe a SU fila de artesano (aprobación instantánea) y el panel
-- admin a artesanos + invitaciones (solicitudes/links en vivo). Realtime respeta la RLS del
-- suscriptor. Idempotente.
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'artesanos'
  ) then
    alter publication supabase_realtime add table public.artesanos;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'invitaciones'
  ) then
    alter publication supabase_realtime add table public.invitaciones;
  end if;
end $$;

-- replica identity FULL: Realtime necesita la fila completa para evaluar la RLS en UPDATE.
alter table public.artesanos replica identity full;
alter table public.invitaciones replica identity full;
