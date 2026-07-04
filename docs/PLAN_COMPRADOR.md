# Plan — Rediseño del comprador + cuentas (Tlachiwalis)

Plan por fases verificado contra el código real (workflow de mapeo). Las fases **[GATE]** tocan
RLS/vistas públicas o tablas nuevas → verificar con la anon key que NO filtran PII ni borradores
antes de aplicar.

## F0 — Refactor previo (sin cambios de datos)
- Crear `apps/web/src/components/pieza-card.tsx` (`<PiezaCard>` reutilizable; hoy duplicada en
  catalog.tsx, page.tsx, tienda/[id]/page.tsx). Badge sobrio "Pieza única"/"Agotado" (texto
  uppercase `text-ceniza`, no pills). Props: id, nombre, maker, region, precio, precioDesde?,
  esDesde?, img, disponibleTotal?, tipo?.
- Editar catalog.tsx, page.tsx, tienda/[id]/page.tsx para usarla.
- Arreglar `getProduct(id)` en `lib/catalog.ts` (query directa `.eq(id).maybeSingle()`, no traer
  todo y filtrar en memoria).

## F1 [GATE RLS] — Capa de datos del comprador
- Migración `0022_storefront_comprador.sql`:
  - Ampliar `productos_storefront` (security_invoker) con `artesano_id, artesano_slug (join a
    artesanos_publicos), categoria_id, tipo_producto`. (precio_desde/disponible_total ya existen.)
  - Redefinir `artesanos_publicos` con campos de marca NO sensibles: foto_portada, redes,
    envia_nacional, tipo_vendedor, nombre_negocio, taller, anios_experiencia, num_personas.
    NO exponer: rfc, regimen_fiscal, clabe, stripe_account_id, telefono, direccion,
    fecha_nacimiento, contacto, nombres/apellidos legales. Mantener `where status='activo'`.
  - Verificar con anon: sin borradores, sin PII.
- Código: `lib/catalog.ts` (seleccionar nuevas columnas + tipo `CardProducto`), crear
  `lib/artesano-publico.ts` (getArtesano(slug), getPiezasDeArtesano), extender `lib/tienda-detalle.ts`
  con bloque `artesano`.

## F2 — Storefront rediseñado (home + secciones + grid)
- page.tsx (hero, "explora por oficio" → `/tienda?oficio=`, muestra de piezas real, banda de
  artesanos enlazable), tienda/page.tsx, catalog.tsx (precio-desde + badges vía PiezaCard).

## F3 — Detalle de producto por TIPO
- tienda/[id]/page.tsx: detectar tipo por estructura (variantes/opciones), badge "Pieza única",
  link al artesano, cantidad para stock_simple. Reusa GaleriaPieza/SelectorVariante/AddToCart.

## F4 — Página pública de artesano
- Crear `app/tienda/artesano/[slug]/page.tsx` + `components/artesano-hero.tsx`. Portada + avatar +
  semblanza + badges + redes (whitelist) + grid de sus piezas publicadas.

## F5 — Filtros + búsqueda + navegación por secciones
- catalog.tsx: filtros en `searchParams` (?oficio=&region=&q=&orden=), búsqueda de texto, región,
  precio. tienda/page.tsx lee searchParams en SSR. Búsqueda NO cae a fallback demo (0 = vacío real).
- (opcional) nav de categorías reales.

## F6 [GATE RLS] — Cuentas de comprador (correo + contraseña)
- Migración `0023_comprador.sql`: tabla `perfiles` (1:1 auth.users, RLS self-only) + trigger
  `handle_new_user` (SECURITY DEFINER, on conflict do nothing — no romper claim de artesano) +
  tabla `direcciones` (RLS self-only). SIN datos de tarjeta.
- apps/api: `POST /buyers/register` (Bearer, admin.createUser email_confirm, rate-limit, zod).
- Web: `app/entrar/`, `app/registrarse/` (MedidorPassword, sin tarjeta), `lib/comprador/auth.ts`
  (requireComprador sin gate de status), `app/cuenta/` (perfil + direcciones). site-header con
  slot de cuenta. proxy.ts matcher `+/cuenta`.
- CONFIG EXTERNA: decidir `GOTRUE_DISABLE_SIGNUP` (Opción A: mantener + crear por service_role),
  `CLAIM_SERVICE_TOKEN` en apps/api, (opcional) SMTP.

## F7 — Google OAuth
- CONFIG EXTERNA (usuario): Google Cloud OAuth client + consent; envs GoTrue
  `GOTRUE_EXTERNAL_GOOGLE_*`, `GOTRUE_URI_ALLOW_LIST` (incluir `/auth/callback`), `GOTRUE_SITE_URL`.
  Redirect URI de Google = `https://supabase.glowel.com.mx/auth/v1/callback` (el de GoTrue).
- Código: `app/auth/callback/route.ts` (exchangeCodeForSession) + botón Google en entrar/registrarse.

## Gotchas transversales
- Imágenes RELATIVAS `/storage/...` vía rewrite (no URLs absolutas). `<Image>` src relativo ya
  probado en FramedImage.
- Detectar los 3 tipos por estructura (variantes/opciones), no solo `tipo_producto`.
- Fallback estático SOLO para home; búsqueda/artesano/detalle → estado vacío real, no demo.
- Next 16: cookies() async, proxy (no middleware); leer node_modules/next/dist/docs/.
- Pedidos/checkout/CFDI fuera de scope; carrito sigue en localStorage.
