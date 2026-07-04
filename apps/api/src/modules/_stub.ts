import { Router } from "express";

/** Router placeholder para módulos del monolito aún no implementados. */
export function stubRouter(name: string) {
  const r = Router();
  r.use((_req, res) => res.status(501).json({ module: name, status: "pendiente" }));
  return r;
}
