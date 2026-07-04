-- 0019_gate_publicar_cobros.sql — FASE 5 (cobros): backstop en BD del gate de publicación.
-- Regla de negocio: una pieza NO puede quedar 'publicado' (comprable) si su artesano no tiene
-- cobros habilitados — sin cuenta Connect lista no hay forma de recibir el pago. La app ya lo
-- valida (mensaje amable), pero por CLAUDE.md el respaldo SIEMPRE es un constraint/trigger de
-- BD, no solo lógica de app. Solo bloquea la TRANSICIÓN a 'publicado' (insert-como-publicado o
-- borrador→publicado); editar una pieza ya publicada no se re-valida.

create or replace function public.exigir_cobros_para_publicar()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'publicado'
     and (tg_op = 'INSERT' or old.status is distinct from 'publicado') then
    if not exists (
      select 1 from public.artesanos a
      where a.id = new.artesano_id and a.cobros_habilitados
    ) then
      raise exception 'cobros_no_habilitados'
        using hint = 'El artesano debe completar su conexión de cobros (Stripe) antes de publicar.';
    end if;
  end if;
  return new;
end;
$$;

-- BEFORE INSERT OR UPDATE OF status: en UPDATE solo dispara si la sentencia toca `status`
-- (editar otros campos de una pieza publicada no re-valida).
drop trigger if exists trg_exigir_cobros_publicar on public.productos;
create trigger trg_exigir_cobros_publicar
  before insert or update of status on public.productos
  for each row execute function public.exigir_cobros_para_publicar();
