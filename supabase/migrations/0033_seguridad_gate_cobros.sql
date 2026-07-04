-- 0033 — Seguridad: gate de publicación ligado a CUENTA Stripe real + es_demo + idempotencia checkout
-- Hallazgo de auditoría: el gate confiaba solo en el booleano `cobros_habilitados`, desacoplado de
-- `stripe_account_id`. El seed de demo forzó `cobros_habilitados=true` sin cuenta → estado imposible
-- en prod y (peor) el checkout cobraba piezas sin ruta de dispersión. Aquí:
--  1) `es_demo`: talleres de exhibición (sin cuenta real) pueden PUBLICAR pero NO se les cobra
--     (el rechazo de compra vive en apps/api recalcularItems).
--  2) El gate exige cobros habilitados CON `stripe_account_id`, salvo `es_demo`.
--  3) `orders.client_key` UNIQUE: idempotencia de checkout (doble submit = misma orden).

alter table public.artesanos add column if not exists es_demo boolean not null default false;

alter table public.orders add column if not exists client_key text;
create unique index if not exists orders_client_key_uidx
  on public.orders(client_key) where client_key is not null;

create or replace function public.exigir_cobros_para_publicar()
returns trigger language plpgsql security definer set search_path to '' as $function$
begin
  if new.status = 'publicado' and (tg_op = 'INSERT' or old.status is distinct from 'publicado') then
    if not exists (
      select 1 from public.artesanos a
      where a.id = new.artesano_id
        and ((a.cobros_habilitados and a.stripe_account_id is not null) or a.es_demo)
    ) then
      raise exception 'cobros_no_habilitados'
        using hint = 'El artesano debe completar su conexión de cobros (Stripe) antes de publicar.';
    end if;
  end if;
  return new;
end;
$function$;

-- Datos: los talleres de demo (sin user real ni cuenta Stripe) pasan a `es_demo` y se les QUITA el
-- flag de cobros fingido (queda honesto: "sin cuenta aún"). Sus piezas siguen publicadas (browsables)
-- pero NO comprables. juan-angel (cuenta Connect real) NO se toca.
update public.artesanos
  set es_demo = true, cobros_habilitados = false, cobros_detalles_enviados = false
  where user_id is null and stripe_account_id is null;
