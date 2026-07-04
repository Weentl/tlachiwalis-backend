-- 0026 — Onboarding del comprador (progresivo, saltable)
-- Tras crear la cuenta (correo+contraseña), un pequeño onboarding pide datos que ayudan a
-- personalizar (nombre/apellido, intereses por oficio → recomendaciones, cómo nos conoció).
-- NO se pide tarjeta ni dirección (eso va hasta el checkout). Todo es opcional / saltable.

alter table public.perfiles
  add column if not exists apellido text,
  add column if not exists intereses text[] not null default '{}',
  add column if not exists como_conocio text,
  add column if not exists onboarding_completo boolean not null default false;
