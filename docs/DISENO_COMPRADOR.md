# Dirección de diseño — Storefront comprador (elegida por panel de 4 Opus + juez)

**Base: "Museo editorial refinado"** + injertos: fuentes reales + filete `unico` + CTA móvil (B),
rigor de conversión/stepper/deep-links/cross-out (C), restraint anti-IA sin oro/sin sombras (D).

## Tokens reales (verificados)
- Fuentes: `font-display` = **Cormorant Garamond** (títulos/precio) · `font-sans` = EB Garamond ·
  `font-serif` (= display, itálica = voz curatorial, para meta) · `font-wordmark` = Bricolage
  (solo nav/versalitas). **NUNCA Space Grotesk en storefront** (es del admin).
- Paleta 60/30/10, acento único **tinto** (#57211d) solo en precio/CTA/estado activo/maya-rule/
  filete. background #f1e9da, card #f7f1e6, foreground/tinta #2b2118, ceniza #8c7c68, arena
  #e5d8c0, barro #b45f39 (solo bandas full-bleed de artesano). **oro VETADO** en storefront.
- Radio 0 en todo excepto swatch de color y retrato humano (`rounded-full`). **Sin sombras**
  (profundidad = doble filete de FramedImage + hairlines `border-ceniza/30`).
- Alineación IZQUIERDA por defecto (centrado solo hero/CTA ceremonial). Encabezados de sección
  con folio numerado ("01 — Oficios"). Medida de lectura `max-w-[62ch]`.

## Vocabulario de badge (un solo badge, prioridad)
Agotado > escasez > tipo. Texto versalita `text-[0.62rem] uppercase tracking-[0.16em]`, nunca pill:
- Agotado (`disponibleTotal<=0`): "Agotado" `text-ceniza` + foto `opacity-70 grayscale-[0.2]`.
- `unico`: "Pieza única" `text-tinto`.
- `stock_simple` y `disponibleTotal<=3`: "Últimas {n}" `text-tinto`.
- `con_variantes`: sin badge (el "desde" ya comunica).

## F3 — Detalle por tipo (`tienda/[id]`)
- Grid `md:grid-cols-2 md:gap-16`, columna derecha `md:sticky md:top-28`. Barra de compra fija en
  móvil. Orden derecha: eyebrow `{oficio}·{region}` → H1 → precio → semblanza → **zona de compra
  por tipo** → nota hecho-a-mano → **bloque del artesano** (retrato `rounded-full` + "Hecho por
  {maker}" + "Ver el taller →" a `/taller/{artesanoSlug}`) → ficha `<dl>` DESPUÉS del CTA.
- **unico:** filete interior tinto reforzado en FramedImage, "Pieza única · ejemplar irrepetible",
  sin cantidad, CTA "Llevar esta pieza". Agotado → desaturar, "encontró su hogar".
- **stock_simple:** `SelectorCantidad` (− n +, celdas `h-11 w-11 border`, clamp 1..disponible),
  "{n} disponibles" / "Solo quedan {n}" (`<=3` text-tinto). CTA "Agregar al carrito" con qty.
- **con_variantes:** chips talla (activo `border-tinto bg-tinto/10`; combo imposible `line-through
  text-ceniza/50 aria-disabled`), swatches color `rounded-full` hex real (activo `ring-2 ring-tinto
  ring-offset-2`, etiqueta del color visible), precio reactivo "desde → exacto" (cross-fade 200ms,
  precio del SERVIDOR nunca recalcular en cliente), SelectorCantidad al resolver variante.
- Extender `add(p, variante, qty)` en `lib/cart.tsx` + `AddToCart` (hoy suma 1 fijo).

## F4 — Artesano (`/taller/[slug]` + `/talleres`)
- Usa `lib/artesano-publico.ts` (sin PII). Portada full-bleed `h-[46svh]` (fotoPortada, fallback
  bg-barro), retrato en `FramedImage aspect-[4/5]` (artesano-como-obra), eyebrow OFICIO·REGIÓN,
  H1, semblanza `max-w-[62ch]` (**sanitizar HTML anti-XSS**), redes como versalitas monocromo
  (nunca logos a color), grid de sus piezas (PiezaCard, disponibles primero, vacío sobrio).
- `/talleres`: índice, grid de cards de taller (retrato + nombre + "oficio · región" + "{n} piezas").

## F5 — Filtros / estados
- Oficio = tabs tipográficas (patrón actual), deep-link `?oficio=` vía useSearchParams. Orden =
  select nativo por ahora. Región/búsqueda: diferir hasta ~40 piezas. Cargando = FramedImage con
  interior `bg-arena animate-pulse`. Vacío = itálica ceniza sobria. Agotadas al final.

## Anti-patrones (NO hacer)
Space Grotesk en storefront · pills de color · sombras/gradientes azules/gris frío (slate/zinc) ·
rojo para "Agotado" (es desaturación) · oro en storefront · iconografía folclórica (sombreros/
calaveras/cactus/sarape/faux-azteca) · centrar todo el producto · barra de "confianza"/breadcrumb
marketplace · sidebars de facetas/dropdowns múltiples · maya-rule como wallpaper · recalcular
precio en cliente.
