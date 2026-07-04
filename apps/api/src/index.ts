import express from "express";
import cors from "cors";
import { config, supabaseConfigured } from "./config";
import { catalogRouter } from "./modules/catalog/routes";
import { sellersRouter } from "./modules/sellers/routes";
import { buyersRouter } from "./modules/buyers/routes";
import { paymentsRouter } from "./modules/payments/routes";
import { webhooksRouter } from "./modules/payments/webhook";
import { stubRouter } from "./modules/_stub";

const app = express();
app.disable("x-powered-by");

// CORS explícito: solo el origen del frontend configurado, métodos y headers
// acotados. Sin credenciales (la API no usa cookies; auth irá por Bearer).
app.use(
  cors({
    origin: config.webOrigin,
    methods: ["GET", "POST"],
    allowedHeaders: ["Content-Type", "Authorization"],
    credentials: false,
    maxAge: 86400,
  }),
);
// Webhook de Stripe: usa RAW body (verificación de firma) → se monta ANTES de express.json.
app.use("/webhooks", webhooksRouter);
// /sellers trae su PROPIO parser JSON (2 MB, para las fotos del registro en base64) → se
// monta ANTES del express.json global de 100kb (que aplica al resto de módulos).
app.use("/sellers", sellersRouter);

app.use(express.json({ limit: "100kb" })); // límite de cuerpo (anti-DoS) para el resto

app.get("/health", (_req, res) =>
  res.json({ ok: true, service: "tlachiwalis-api", supabase: supabaseConfigured }),
);

// ----- Monolito modular: cada módulo es dueño de su frontera -----
app.use("/catalog", catalogRouter); // implementado (lectura)
app.use("/buyers", buyersRouter); // alta de comprador (service_role)
app.use("/identity", stubRouter("identity")); // auth/roles — pendiente
app.use("/orders", stubRouter("orders")); // órdenes (outbox) — pendiente
app.use("/payments", paymentsRouter); // guardar tarjetas del comprador (SetupIntent + Payment Element)
app.use("/tax", stubRouter("tax")); // retenciones ISR/IVA + CFDI — pendiente
app.use("/shipping", stubRouter("shipping")); // envíos — pendiente

app.listen(config.port, () => {
  console.log(`Tlachiwalis API → http://localhost:${config.port}  (supabase: ${supabaseConfigured})`);
});
