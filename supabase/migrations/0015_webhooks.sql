-- 0015_webhooks.sql — IDEMPOTENCIA de webhooks (CLAUDE.md: tabla con UNIQUE(event_id)).
-- El receptor inserta-o-salta por event_id: si ya existe, el evento ya se procesó → 200.
-- Backend-only: solo el servicio con service_role (apps/api) la toca; anon/authenticated no.
create table if not exists public.processed_webhook_events (
  event_id text primary key,            -- id del evento de Stripe (evt_…) — respaldo de idempotencia
  tipo text,
  recibido_en timestamptz not null default now()
);

alter table public.processed_webhook_events enable row level security;
-- Sin policies → nadie salvo service_role (que bypassa RLS) accede. Revoca el grant directo.
revoke all on public.processed_webhook_events from anon, authenticated;
