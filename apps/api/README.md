# Tlachiwalis API — backend Express (monolito modular)

Servicio Node/Express que concentra la **lógica sensible** del marketplace: checkout,
pagos (Stripe + Connect), retenciones ISR/IVA, CFDI (PAC) y dispersión. Es la **frontera
de confianza**: aquí viven las llaves secretas y la autoridad de precios.

## Módulos (frontera por dominio)
- `catalog` — lectura de piezas. **Implementado** (`GET /catalog/products`, `/catalog/products/:id`).
- `identity` — auth/roles. _pendiente_
- `sellers` — artesanos/vendedores. _pendiente_
- `orders` — órdenes con patrón outbox. _pendiente_
- `payments` — Stripe + Connect (split/dispersión). _pendiente_
- `tax` — retenciones + CFDI vía PAC. _pendiente_
- `shipping` — envíos. _pendiente_

Cada módulo crecerá en su carpeta `src/modules/<modulo>/`. Los pendientes responden 501.

## Correr
```bash
cp .env.example .env.local   # y pega SUPABASE_URL + SUPABASE_SECRET_KEY
pnpm --filter api dev        # http://localhost:4000/health
```

La `SUPABASE_SECRET_KEY` (bypassa RLS) vive SOLO aquí. El frontend usa la publishable key + RLS.
