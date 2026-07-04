-- 0018_cobros.sql — FASE 1 (cobros): estado de Stripe Connect del artesano.
-- El artesano APROBADO ('activo') accede al panel y puede crear piezas (borrador), pero NO
-- puede PUBLICAR (vender) hasta tener cobros habilitados: sin cuenta Connect no hay forma de
-- recibir el pago. `stripe_account_id` ya existe (0013). Lo llena el webhook account.updated.
alter table public.artesanos
  -- charges_enabled/payouts_enabled de su cuenta Connect → puede recibir pagos.
  add column if not exists cobros_habilitados boolean not null default false,
  -- details_submitted: terminó el formulario de Stripe (puede seguir "en revisión").
  add column if not exists cobros_detalles_enviados boolean not null default false;
