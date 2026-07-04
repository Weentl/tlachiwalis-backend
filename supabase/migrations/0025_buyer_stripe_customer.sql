-- 0025 — Stripe Customer del comprador (guardar tarjetas)
-- El Customer vive en la cuenta PLATAFORMA (Tlachiwalis = merchant of record; Connect dispersa a
-- los artesanos con destination charges). Se crea PEREZOSAMENTE al guardar la primera tarjeta.
-- Guardamos SOLO el id del Customer; el número de tarjeta NUNCA toca nuestra BD (PCI SAQ-A):
-- Stripe guarda el PaymentMethod, nosotros mostramos brand/last4/exp vía la API con service_role.
-- RLS: perfiles ya es self-only para authenticated; getPerfil() NO expone esta columna al cliente.

alter table public.perfiles
  add column if not exists stripe_customer_id text unique;
