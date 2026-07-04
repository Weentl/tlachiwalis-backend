-- ============================================================================
-- SEED DEMO VENDEDOR (1@gmail.com = artesano juan-angel-colorado-pacheco)
-- Publicaciones de PRUEBA de todos los tipos que el artesano puede subir:
--   con_variantes (ropa: talla+color, y solo-color), stock_simple, unico.
-- Con multi-foto (producto_imagenes) y ejes reales de la taxonomía (0007).
-- Identificador: ids con prefijo `demo-`. NO toca el mock demo (tal-/bar-/ale-/…).
-- Idempotente. Imágenes: /public/images (storage_path absoluto pasa directo).
-- ============================================================================

\set art '1482a2af-e34d-4069-b0b8-52de34a4b5a9'

-- Limpieza previa (solo lo `demo-`).
delete from public.producto_imagenes where producto_id like 'demo-%';
delete from public.inventario i using public.producto_variantes pv
  where i.variante_id = pv.id and pv.producto_id like 'demo-%';
delete from public.producto_variantes where producto_id like 'demo-%';
delete from public.productos where id like 'demo-%';

-- ---- Productos ----
insert into public.productos
  (id, artesano_id, nombre, maker, oficio, region, precio_centavos, imagen, descripcion, tecnica, materiales, medidas, categoria_id, tipo_producto, status, destacado, tendencia, created_at)
values
 ('demo-blusa', :'art', 'Blusa bordada a mano', 'Juan Ángel Colorado', 'Telar de cintura', 'Chiapas', 89000, '/images/huipil-1.jpg',
  'Blusa de manta bordada a mano con motivos florales. Elige tu talla y color; el bordado varía ligeramente en cada pieza.', 'Bordado a mano en telar', 'Algodón de manta, hilo teñido', 'Ver guía de tallas', 3, 'con_variantes', 'publicado', true, true, now()-interval '5 days'),
 ('demo-huipil', :'art', 'Huipil ceremonial', 'Juan Ángel Colorado', 'Telar de cintura', 'Chiapas', 245000, '/images/textile-1.jpg',
  'Huipil ceremonial tejido en telar de cintura, con brocados que cuentan la historia del pueblo. Disponible por talla.', 'Telar de cintura, brocado a mano', 'Algodón y lana teñidos con tintes naturales', 'Talla según selección', 3, 'con_variantes', 'publicado', false, true, now()-interval '9 days'),
 ('demo-tapete', :'art', 'Tapete de lana tejido', 'Juan Ángel Colorado', 'Telar de cintura', 'Oaxaca', 165000, '/images/textile-2.jpg',
  'Tapete de lana tejido en telar de pie, teñido con tintes naturales. Elige el color que combine con tu espacio.', 'Telar de pie, tinte natural', 'Lana teñida (grana, añil, nuez)', '1.5 m × 1 m', 4, 'con_variantes', 'publicado', false, false, now()-interval '3 days'),
 ('demo-taza', :'art', 'Taza de barro negro', 'Juan Ángel Colorado', 'Barro negro', 'Oaxaca', 32000, '/images/pottery-2.jpg',
  'Taza de barro negro bruñido, perfecta para el café de la mañana. Hecha en serie corta.', 'Barro negro bruñido', 'Arcilla negra de Oaxaca', '9 cm de alto · 250 ml', 1, 'stock_simple', 'publicado', false, false, now()-interval '6 days'),
 ('demo-vasija', :'art', 'Vasija escultórica única', 'Juan Ángel Colorado', 'Barro negro', 'Oaxaca', 480000, '/images/pottery-1.jpg',
  'Vasija escultórica de barro negro, modelada y bruñida a mano. Pieza única, irrepetible.', 'Modelado y bruñido a mano', 'Arcilla negra de Oaxaca', '42 cm de alto', 1, 'unico', 'publicado', true, false, now()-interval '2 days');

-- ---- Variantes (opciones usan los codigos/valores reales de la taxonomía) ----
-- Blusa: talla CH/M/G × color blanco/azul (6). G cuesta +$150. M-azul agotada (demo cross-out).
insert into public.producto_variantes (producto_id, sku, opciones, precio_delta_centavos, activa) values
 ('demo-blusa','demo-blusa-CH-blanco','{"talla":"CH","color":"blanco"}'::jsonb, 0, true),
 ('demo-blusa','demo-blusa-CH-azul','{"talla":"CH","color":"azul"}'::jsonb, 0, true),
 ('demo-blusa','demo-blusa-M-blanco','{"talla":"M","color":"blanco"}'::jsonb, 0, true),
 ('demo-blusa','demo-blusa-M-azul','{"talla":"M","color":"azul"}'::jsonb, 0, true),
 ('demo-blusa','demo-blusa-G-blanco','{"talla":"G","color":"blanco"}'::jsonb, 15000, true),
 ('demo-blusa','demo-blusa-G-azul','{"talla":"G","color":"azul"}'::jsonb, 15000, true),
-- Huipil: solo talla CH/M/G.
 ('demo-huipil','demo-huipil-CH','{"talla":"CH"}'::jsonb, 0, true),
 ('demo-huipil','demo-huipil-M','{"talla":"M"}'::jsonb, 0, true),
 ('demo-huipil','demo-huipil-G','{"talla":"G"}'::jsonb, 20000, true),
-- Tapete: solo color negro/cafe/multicolor.
 ('demo-tapete','demo-tapete-negro','{"color":"negro"}'::jsonb, 0, true),
 ('demo-tapete','demo-tapete-cafe','{"color":"cafe"}'::jsonb, 0, true),
 ('demo-tapete','demo-tapete-multicolor','{"color":"multicolor"}'::jsonb, 25000, true),
-- Simple / único: variante default vacía.
 ('demo-taza','demo-taza-u','{}'::jsonb, 0, true),
 ('demo-vasija','demo-vasija-u','{}'::jsonb, 0, true);

-- ---- Inventario (disponible es GENERADA: solo stock/reservado) ----
insert into public.inventario (variante_id, stock, reservado)
select pv.id, s.stock, 0
from public.producto_variantes pv
join (values
  ('demo-blusa-CH-blanco',5),('demo-blusa-CH-azul',3),('demo-blusa-M-blanco',4),
  ('demo-blusa-M-azul',0),('demo-blusa-G-blanco',2),('demo-blusa-G-azul',6),
  ('demo-huipil-CH',3),('demo-huipil-M',2),('demo-huipil-G',1),
  ('demo-tapete-negro',4),('demo-tapete-cafe',3),('demo-tapete-multicolor',2),
  ('demo-taza-u',20),('demo-vasija-u',1)
) as s(sku, stock) on s.sku = pv.sku;

-- ---- Multi-foto (galería) ----
insert into public.producto_imagenes (producto_id, storage_path, alt, orden, es_principal) values
 ('demo-blusa','/images/huipil-1.jpg','Blusa bordada — frente', 0, true),
 ('demo-blusa','/images/textile-1.jpg','Blusa bordada — detalle del bordado', 1, false),
 ('demo-blusa','/images/textile-2.jpg','Blusa bordada — textil', 2, false),
 ('demo-huipil','/images/textile-1.jpg','Huipil ceremonial — completo', 0, true),
 ('demo-huipil','/images/huipil-1.jpg','Huipil ceremonial — brocado', 1, false),
 ('demo-tapete','/images/textile-2.jpg','Tapete de lana — completo', 0, true),
 ('demo-tapete','/images/textile-1.jpg','Tapete de lana — textura', 1, false),
 ('demo-taza','/images/pottery-2.jpg','Taza de barro negro', 0, true),
 ('demo-vasija','/images/pottery-1.jpg','Vasija escultórica — frente', 0, true),
 ('demo-vasija','/images/pottery-2.jpg','Vasija escultórica — perfil', 1, false);
