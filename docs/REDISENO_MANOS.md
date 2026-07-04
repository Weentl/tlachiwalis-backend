# Rediseño del comprador — Dirección "Manos"

Reemplaza por completo la dirección anterior ("museo editorial": Cormorant/EB Garamond,
radios 0px, doble filete de museo, grecas `.maya-rule` como divisor). Origen: panel de
investigación (Amazon/ML/Shopify/Etsy + LFPDPPP + Stripe) + 3 conceptos (uno con Fable) +
síntesis. **Solo storefront** — admin y vendedor NO se tocan.

## Idea
De la vitrina a **las manos**: retrato-first, tintes mexicanos reales, la FOTO trae la
saturación y la UI queda en neutros cálidos + **un solo acento de acción (grana)**.

## Sistema de diseño (`apps/web/src/app/globals.css`)
- **Tipografía** (layout.tsx, `next/font`): `--font-display` **Fraunces** (héroes/títulos/
  nombres/citas) · `--font-sans` **Hanken Grotesk** (todo lo funcional) · `--font-mono`
  **Space Mono** (micro-etiquetas de origen, nº de pedido). Admin sigue en IBM Plex/Space Grotesk.
- **Color** (`:root`): cal `#FAF6EF` · arena `#ECE3D4` · lino `#FFFDF9` · tinta `#211C15` ·
  ceniza `#8C7C68` · linea `#E7DDCC`. Firma **grana** `#B4324E` (CTA/precio/activo; hover
  `grana-viva #E0567A`, nunca texto). Confianza **añil** `#26324F`. Éxito **jade** `#127A63`.
  "Hecho a mano" **cempasúchil** `#E9A23B`. Regla: un solo acento de acción por pantalla.
- **Radios** 10–20px (adiós al 0px). **Sombras** cálidas tintadas (`shadow-cta/pieza/alto`).
- **Firmas**: `.portal` (máscara de arco), `.hilo` (puntada grana, divisor/subrayado con
  disciplina extrema), Pasaporte de la pieza (datos duros), micro-etiquetas mono.

## Protección del admin/vendedor
`:root` es el tema del storefront (default público). La clase **`.panel`** restaura la paleta
original (tierra + tinto) y se aplica a los 5 puntos de entrada del panel
(`admin/(panel)/layout`, `admin/login`, `vendedor/(panel)/layout`, `vendedor/login`,
`vendedor/pendiente`). Admin/vendedor quedan visualmente idénticos. `.dark/.obsidian/.card-warm/.ob-*`
y `--font-admin/--font-grotesk` intactos.

## Componentes
- Nuevos: `ui/boton.tsx` (Boton + `botonCls`, distinto del `<Button>` del panel), `ui/hilo.tsx`,
  `ui/skeleton.tsx` (Skeleton + GridSkeleton), `trust-row.tsx`, `pasaporte-pieza.tsx`,
  `cart-drawer.tsx`.
- Rehechos: `framed-image.tsx` → `MediaFrame` (+variante Portal; `FramedImage` queda como alias),
  `pieza-card.tsx` → ProductCard (MediaFrame, badges pill, meta mono, precio grana, lift),
  `site-header.tsx` (búsqueda GET `/tienda?buscar=`, cart drawer, menú cuenta),
  `catalog.tsx` (chips-pill + barra sticky + bottom sheet móvil + `initialQ`),
  `cart-view.tsx` (stepper, tokens Manos), `selector-variante.tsx` (swatches anillo grana,
  chips pill), `selector-cantidad.tsx` (stepper redondeado), `galeria-pieza.tsx` (MediaFrame),
  `add-to-cart.tsx` (CTA grana pill), `tienda/[id]/page.tsx` (eyebrow mono, Fraunces, Pasaporte,
  bloque artesano con retrato, Hilo).
- Carrito (`lib/cart.tsx`): + estado del drawer (`open/openCart/closeCart`) + `setQty`; `add` abre
  el drawer.

## Estado de fases — TODAS HECHAS (F0–F6)
- **F0 · Piel base** ✅ (tokens + fuentes + MediaFrame + Boton + `.panel`).
- **F1 · Descubrir** ✅ (ProductCard + header con búsqueda/cuenta + CartDrawer + filtros chips/sheet).
- **F2 · Detalle** ✅ (PDP por tipo + Pasaporte + swatches + artesano). *Diferido*: View Transitions
  grid→detalle y StickyAddToCartBar móvil.
- **F3 · Talleres** ✅ (`/talleres` directorio + `/taller/[slug]` documental: hero portada, retrato
  Portal, ficha de datos). Mejora futura: fotos/video reales (el diseño ya los soporta).
- **F4 · Registro** ✅ — mínimo (correo+contraseña, Google-first, sin teléfono, nombre opcional) +
  consentimientos separados no premarcados + `/aviso-de-privacidad` (LFPDPPP/ARCO). Backend
  `buyers` `nombre` opcional + `marketing_consent`. **Migración 0024** (consent en perfiles +
  `handle_new_user`). E2E verificado. Pend. config: Google OAuth consola / SMTP (fallback auto-confirm).
- **F5 · Mi cuenta** ✅ — dashboard (nav añil: Perfil/Direcciones/Métodos de pago/Pedidos/
  Privacidad). Direcciones con predeterminada. ARCO: toggle marketing, descargar datos JSON
  (`/cuenta/datos`), **eliminar cuenta** (apps/api `POST /buyers/delete-account` + `requireBuyer`,
  con guarda anti-borrado de artesanos/admins). E2E verificado.
- **F6 · Pagos Stripe** ✅ — guardar tarjetas (Customer en plataforma lazy + SetupIntent + Payment
  Element). **Migración 0025** `stripe_customer_id`. api `payments/routes.ts` (reemplaza stub 501):
  setup-intent / list / detach / default + `requireBuyer` (anti-IDOR por `pm.customer`) + webhook
  `case setup_intent.succeeded` (1ª tarjeta = default). web: `@stripe/stripe-js` +
  `@stripe/react-stripe-js`; `MetodosPago`/`PaymentMethodCard`/`AddCardForm` +
  `/cuenta/metodos-de-pago/agregar`. PCI = SAQ-A. E2E backend verificado; **falta** capturar una
  tarjeta de prueba (4242…) en el navegador para validar el confirmSetup visual.

## Ronda 2 — Marketplace, navbar, landing, onboarding, seed (blueprint de Fable)
- **Onboarding post-registro** (`/registrarse/onboarding`, mig **0026**): tras crear cuenta, pide
  nombre/apellido + **intereses** (oficios → recomendaciones) + cómo nos conoció; todo saltable
  (`omitirOnboarding`). Sin tarjeta/dirección.
- **Stripe Link fuera**: `add-card-form.tsx` usa **CardElement** + `confirmCardSetup` (solo campos de
  tarjeta; sin la caja correo/celular/nombre de Link).
- **Datos de prueba** (`supabase/seed_demo_manos.sql`, idempotente): 8 talleres demo (sin user_id,
  status activo, `cobros_habilitados` para pasar el gate 0019) + **14 piezas** con variante+inventario
  (imágenes `/public`), flags `destacado`/`tendencia` + `created_at` escalonado. `urlPublicaPieza`
  ahora deja pasar rutas absolutas `/images`.
- **Migración 0027**: `productos.destacado/tendencia` + la vista `productos_storefront` expone
  `publicado_en/destacado/tendencia`. `CardProducto`/`catalog.ts` extendidos. `lib/escaparate.ts`:
  helpers puros (tendencia/novedades/unicas/porOficio/recomendados/regionesConteo/oficiosVitrina).
- **Navbar** (`site-header`): **Tienda** (antes "Piezas") con submenú de oficios, **Artesanos**
  (antes "Talleres"), **Nuestra historia**; estado activo (puntada `.hilo` + `aria-current`); fix
  búsqueda `onBlur` (solo cierra si vacía).
- **Landing** (`page.tsx` reorganizado): Hero (CTA botón grana + link a /talleres, eyebrow mono) →
  TrustRow → OficioTiles (arco Portal) → PiezaRail "En tendencia" → TallerSpotlight (añil, Macrina) →
  PiezaRail "Recién del taller" → Piezas únicas (grid) → RegionesBand → CierreCta (grana + hilo).
  Nuevos componentes: `pieza-rail`, `oficio-tiles`, `taller-spotlight`, `regiones-band`, `cierre-cta`.
- **Tienda escaparate** (`catalog.tsx`): modo **escaparate** (carriles tendencia/novedades/por-oficio
  + "Todo el catálogo") vs **resultados** (rejilla) según filtros. Filtros: oficio/región/tipo/precio
  + toggle agotadas; **chips activos** removibles + meta ("N piezas · de $X a $Y"); bottom sheet
  (móvil) / panel lateral (desktop). H1 "La tienda" + línea de datos reales + nota MXN.
- **maya eliminada** de `globals.css`; `formatMXN` → `es-MX`.

## Ronda 3 — Mi cuenta (blueprint de Fable), Nuestra historia, precios MXN
- **Mi cuenta rediseñada** (blueprint de Fable): se quitaron los bloques oscuros (nav sin `bg-anil`,
  chip de tarjeta a `bg-anil/10 text-anil`; añil solo como tinte de confianza). Nav con puntada activa
  (`.hilo` + aria-current). **Perfil rico**: `avatar-iniciales` (arco Portal), tarjeta de identidad con
  **correo de registro** (badge jade "Verificado" vía `email_confirmed_at`) + "En Tlachiwalis desde…"
  (`created_at`), `perfil-progreso` (barra jade + checklist), formulario con **apellido** + **intereses**
  (`chips-intereses`, reutilizado en onboarding). **Privacidad** en 3 tarjetas + `ui/interruptor` (switch
  jade) con fecha de consentimiento; zona de eliminar suavizada. Pedidos vacío con CTA. Orden: Perfil ·
  Pedidos · Direcciones · Pagos · Privacidad.
- **Plomería:** `getPerfil` amplía `PerfilComprador` (apellido, intereses, marketing_consent_at,
  como_conocio); `actualizarPerfil` con **whitelist** {nombre,apellido,telefono,intereses} (intereses
  validados contra la lista real de oficios, anti mass-assignment; sentinel `_intereses`). Sin migración
  nueva (columnas ya existían de 0024/0026).
- **Nuestra historia** (`/marca`): reescrita de un "brand board" interno viejo a página pública Manos
  (propósito, cómo funciona, etimología náhuatl, promesas, cierre). **Sin datos inventados** (nada de
  métricas falsas).
- **Precios con "MXN"** junto al monto (cards, PDP, subtotales de carrito/drawer). `formatMXN` ya es es-MX.

## Pendiente estético menor
El **Home ya está reorganizado** (ronda 2). Queda `site-footer.tsx` con composición legacy (renderiza
con la piel nueva pero sin re-componer). Opcional a futuro: video loops en el Hero + `VistoRecientemente`
(carril de "vistos" por localStorage, diferido) + variantes reales con ejes de categoría (hoy el seed
usa único/stock para robustez, sin "desde $").
