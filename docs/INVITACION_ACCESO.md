# Tlachiwalis — Invitación de artesanos y seguridad de acceso

> Diseño de acceso **privado por invitación** (marketplace curado). El admin invita; nadie se registra solo. Complementa el roadmap del panel de vendedor (ver `MODELO_PRODUCTO.md`, Fase 5).

## Modelo de roles
- **Admin** — ya existe: `public.admins` + `is_admin()`.
- **Vendedor** — nuevo: un `auth.user` **ligado a un artesano** vía `artesanos.user_id`. Es vendedor quien "posee" un artesano → helper `es_vendedor()` / `mi_artesano_id()`. Ve/edita **solo lo suyo** (RLS por `user_id`).
- Registro público **deshabilitado** (`GOTRUE_DISABLE_SIGNUP=true`).

## Flujo de invitación (WhatsApp-first, sin depender de SMTP)
Los artesanos en México viven en WhatsApp y muchos no revisan correo → **enlace con token**, no invite por email.

1. **Admin → "Invitar artesano":** captura lo básico (nombre, oficio, estado) → crea el artesano en estado `pendiente` + genera un **token de invitación** → link `tlachiwalis.com/unirse?t=XXXX`.
2. **Admin comparte el link** por WhatsApp/como quiera (botón "Copiar" / "Compartir por WhatsApp").
3. **El artesano abre el link → "Únete a Tlachiwalis":** correo + contraseña (+ acepta términos) → se crea su cuenta y el token la **liga al artesano**. Cae en **su** panel de vendedor.
4. **Onboarding progresivo:** puede cargar productos sin RFC; el **RFC/CLABE/régimen se piden después**, al activar cobros (Stripe Connect). Separar **"puedo publicar"** de **"puedo cobrar"**.

## Seguridad del acceso (capas)
**Token de invitación:** aleatorio (≥32 bytes), **guardado HASHEADO** en BD (si se filtra la BD no hay tokens válidos), **un solo uso**, **expira** (7 días), ligado a UN artesano, revocable por el admin.

**Creación de la cuenta (claim) sin SMTP:** se hace **server-side con privilegio** — Edge Function de Supabase (nativo en cloud) o `apps/api` con `service_role`, usando `admin.createUser({ email_confirm: true })`. **Nunca desde el cliente.**

**RLS del vendedor:** edita **solo su fila** de `artesanos` (`user_id = auth.uid()`) y **no** campos sensibles (comisión, status, no puede auto-aprobarse → whitelist); CRUD solo de **sus** productos (`artesano_id` = su artesano). El admin conserva todo. Verificado en Postgres, no solo en la app.

**Cuentas admin (mayor valor):** MFA/TOTP (Supabase lo soporta), rate limiting (ya existe), **HTTPS** (en cloud), pocas cuentas admin, bitácora de auditoría.

## Datos a agregar (migración, ~Fase 5 / 0012)
```
artesanos.user_id  uuid  references auth.users   (null hasta que reclama la invitación)
invitaciones(id, artesano_id, token_hash, email?, expira_en, usado_en, creada_por, status)  -- one-time, TTL
+ helper es_vendedor() / mi_artesano_id()  +  políticas RLS "dueño" para artesanos/productos/storage
+ bucket privado 'fiscal' (RFC/CLABE/comprobantes) — NO en el bucket público 'piezas'
```

## Dónde encaja
1. Modelo de producto (ver `MODELO_PRODUCTO.md`).
2. **Roles + invitación** (este doc).
3. Panel de vendedor (CRUD por-vendedor sobre el nuevo modelo).
4. Stripe Connect (onboarding + RFC/CLABE + dispersión/retención).

> El claim necesita `service_role` (Edge Function / `apps/api`) — pendiente en self-hosted, **nativo en Supabase Cloud** (otra razón para migrar a cloud antes de vendedores).
