-- 0011_artesano_datos.sql — datos de ALTA del artesano.
-- El admin captura MÍNIMO al invitar: nombre, taller/comercio y un contacto. El artesano
-- llena su perfil público (oficio/semblanza/foto) después; los fiscales (rfc/regimen/clabe)
-- salen del panel y se dan de alta en Stripe (Fase 6). Aditivo, idempotente, no destructivo.
alter table public.artesanos
  add column if not exists taller text,     -- nombre del taller o comercio (marca pública)
  add column if not exists contacto text;   -- correo o WhatsApp para enviarle la invitación
