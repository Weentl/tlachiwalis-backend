-- ============================================================================
-- SEED DEMO "Manos" — datos de prueba del storefront (NO producción).
-- 8 talleres demo (sin user_id, status activo) + 14 piezas con variante+inventario.
-- Imágenes: /public/images (product.imagen se sirve directo; artesano vía urlPublicaPieza
-- que ahora deja pasar rutas absolutas /images). Flags destacado/tendencia (mig 0027) +
-- created_at escalonado (para "Recién del taller"). Idempotente.
-- ============================================================================

-- Limpieza previa (solo lo sembrado por este script).
delete from public.inventario i using public.producto_variantes pv
  where i.variante_id = pv.id and pv.producto_id like any (array['tal-%','bar-%','ale-%','tel-%','ces-%']);
delete from public.producto_variantes where producto_id like any (array['tal-%','bar-%','ale-%','tel-%','ces-%']);
delete from public.productos where id like any (array['tal-%','bar-%','ale-%','tel-%','ces-%']);
delete from public.artesanos
  where user_id is null
    and slug in ('talavera-hnos','macrina-pacheco','taller-coyotepec','taller-linares','familia-ortega','rosa-hernandez','coop-vida-nueva','coop-tenango');

-- ---- Talleres demo (artesanos) ----
insert into public.artesanos (slug, nombre, region, oficio, semblanza, taller, anios_experiencia, num_personas, envia_nacional, foto_url, foto_portada, redes, status, tipo_vendedor, onboarding_completo)
values
 ('talavera-hnos','Talavera Hermanos','Puebla','Talavera',
  'Tres generaciones vidriando barro poblano a mano. Cada plato se pinta con óxidos minerales y se cuece a alta temperatura, como en el siglo XVII.',
  'Talavera Hermanos', 25, 4, true, '/images/talavera-1.jpg', '/images/talavera-2.jpg', '{"instagram":"talaverahnos"}'::jsonb, 'activo', 'taller', true),
 ('macrina-pacheco','Macrina Pacheco','Oaxaca','Barro negro',
  'El barro me enseñó la paciencia. En San Bartolo Coyotepec lo bruño con cuarzo hasta sacarle su brillo negro; cada pieza nace del torno de mano y el horno de leña.',
  'Taller de Macrina', 34, 2, true, '/images/hero-opt-1-workshop.jpg', '/images/pottery-1.jpg', '{"instagram":"macrinapacheco"}'::jsonb, 'activo', 'taller', true),
 ('taller-coyotepec','Taller Coyotepec','Oaxaca','Barro negro',
  'Barro negro mate y bruñido, modelado a mano con las formas tradicionales de nuestro pueblo.',
  'Taller Coyotepec', 20, 5, true, '/images/pottery-2.jpg', '/images/pottery-1.jpg', '{}'::jsonb, 'activo', 'taller', true),
 ('taller-linares','Taller Linares','Edo. de México','Barro negro',
  'Modelamos catrinas y calacas en barro, homenaje a la tradición del Día de Muertos, pintadas a mano una por una.',
  'Taller Linares', 28, 4, true, '/images/catrina-1.jpg', '/images/catrina-1.jpg', '{}'::jsonb, 'activo', 'taller', true),
 ('familia-ortega','Familia Ortega','Oaxaca','Alebrijes',
  'Tallamos copal y pintamos a pincel fino con grecas zapotecas. Cada alebrije es un ser único que nace de un sueño.',
  'Familia Ortega', 30, 5, true, '/images/alebrije-1.jpg', '/images/alebrije-2.jpg', '{"instagram":"familiaortega"}'::jsonb, 'activo', 'taller', true),
 ('rosa-hernandez','Rosa Hernández','Chiapas','Telar de cintura',
  'Tejo en telar de cintura como me enseñó mi madre en Zinacantán, con brocados de flores que cuentan de dónde venimos.',
  'Cooperativa Zinacantán', 18, 8, true, '/images/huipil-1.jpg', '/images/textile-1.jpg', '{}'::jsonb, 'activo', 'taller', true),
 ('coop-vida-nueva','Cooperativa Vida Nueva','Oaxaca','Telar de cintura',
  'Mujeres zapotecas tejiendo con tintes naturales de grana cochinilla y añil. Cada hebra pasa por nuestras manos.',
  'Coop. Vida Nueva', 15, 12, true, '/images/textile-2.jpg', '/images/textile-1.jpg', '{}'::jsonb, 'activo', 'taller', true),
 ('coop-tenango','Cooperativa Tenango','Hidalgo','Cestería',
  'Tejemos palma real con patrones geométricos que pasan de madre a hija. Firmes para el uso diario, bonitas para toda la vida.',
  'Coop. Tenango', 12, 6, true, '/images/handicraft-1.jpg', '/images/handicraft-2.jpg', '{}'::jsonb, 'activo', 'taller', true);

-- Los talleres demo son de EXHIBICIÓN: `es_demo=true` (no cuenta Stripe real). El gate 0033 les
-- permite PUBLICAR sus piezas (browsables), pero NO se les cobra (recalcularItems rechaza la compra).
-- NO se finge `cobros_habilitados` (queda honesto: "sin cuenta aún" en el admin).
update public.artesanos set es_demo = true
  where user_id is null
    and slug in ('talavera-hnos','macrina-pacheco','taller-coyotepec','taller-linares','familia-ortega','rosa-hernandez','coop-vida-nueva','coop-tenango');

-- ---- Piezas ----
insert into public.productos
  (id, artesano_id, nombre, maker, oficio, region, precio_centavos, imagen, descripcion, tecnica, materiales, medidas, categoria_id, tipo_producto, status, destacado, tendencia, created_at)
values
 ('tal-01',(select id from public.artesanos where slug='talavera-hnos'),'Plato de Talavera «Cobalto»','Talavera Hermanos','Talavera','Puebla',129000,'/images/talavera-1.jpg',
  'Plato decorativo de Talavera poblana, esmaltado y pintado a mano con motivos en azul cobalto sobre fondo blanco.','Mayólica esmaltada, alta temperatura','Barro de Puebla, esmaltes minerales','28 cm de diámetro',1,'stock_simple','publicado',false,true, now()-interval '25 days'),
 ('tal-02',(select id from public.artesanos where slug='talavera-hnos'),'Jarra de Talavera «Flor de mayo»','Talavera Hermanos','Talavera','Puebla',164000,'/images/talavera-2.jpg',
  'Jarra de Talavera para agua o flores, vidriada y decorada a mano con flores de mayo.','Mayólica esmaltada','Barro de Puebla, esmaltes minerales','26 cm de alto',1,'stock_simple','publicado',true,false, now()-interval '36 days'),
 ('tal-03',(select id from public.artesanos where slug='talavera-hnos'),'Set de 4 tazas de Talavera','Talavera Hermanos','Talavera','Puebla',78000,'/images/talavera-1.jpg',
  'Juego de cuatro tazas de Talavera pintadas a mano, ideales para el café de la mañana.','Mayólica esmaltada','Barro de Puebla, esmaltes minerales','9 cm de alto c/u',1,'stock_simple','publicado',false,true, now()-interval '28 days'),
 ('bar-01',(select id from public.artesanos where slug='macrina-pacheco'),'Olla de barro negro bruñido','Macrina Pacheco','Barro negro','Oaxaca',185000,'/images/pottery-1.jpg',
  'Olla de barro negro bruñido de San Bartolo Coyotepec, pulida con cuarzo hasta lograr su brillo característico.','Barro negro bruñido, horno de leña','Arcilla negra de Oaxaca','22 × 20 cm',1,'unico','publicado',true,true, now()-interval '30 days'),
 ('bar-02',(select id from public.artesanos where slug='taller-coyotepec'),'Cántaro de barro negro mate','Taller Coyotepec','Barro negro','Oaxaca',142000,'/images/pottery-2.jpg',
  'Cántaro de barro negro mate, modelado a mano con formas tradicionales oaxaqueñas.','Barro negro, modelado a mano','Arcilla negra de Oaxaca','30 × 18 cm',1,'stock_simple','publicado',false,false, now()-interval '15 days'),
 ('bar-03',(select id from public.artesanos where slug='taller-linares'),'Catrina «La Elegante»','Taller Linares','Barro negro','Edo. de México',220000,'/images/catrina-1.jpg',
  'Catrina modelada en barro y pintada a mano, homenaje a la tradición del Día de Muertos.','Modelado en barro, pintura a mano','Barro y pigmentos','38 cm de alto',1,'unico','publicado',false,false, now()-interval '4 days'),
 ('ale-01',(select id from public.artesanos where slug='familia-ortega'),'Alebrije jaguar «Balam»','Familia Ortega','Alebrijes','Oaxaca',340000,'/images/alebrije-1.jpg',
  'Alebrije tallado en copal y pintado a mano con grecas y puntillismo zapoteco. Pieza única.','Talla en copal, pintura a pincel fino','Madera de copal','32 cm de largo',2,'unico','publicado',true,true, now()-interval '33 days'),
 ('ale-02',(select id from public.artesanos where slug='familia-ortega'),'Alebrije venado «Guiexhuba»','Familia Ortega','Alebrijes','Oaxaca',298000,'/images/alebrije-2.jpg',
  'Venado alebrije en copal, con cornamenta tallada y decoración policroma.','Talla en copal, pintura a pincel','Madera de copal','26 cm de alto',2,'unico','publicado',false,false, now()-interval '3 days'),
 ('tel-01',(select id from public.artesanos where slug='rosa-hernandez'),'Huipil de Zinacantán','Rosa Hernández','Telar de cintura','Chiapas',260000,'/images/huipil-1.jpg',
  'Huipil tejido en telar de cintura por manos tzotziles de Zinacantán, con brocados florales.','Telar de cintura, brocado a mano','Algodón y lana teñidos','Talla única',3,'stock_simple','publicado',true,false, now()-interval '40 days'),
 ('tel-02',(select id from public.artesanos where slug='rosa-hernandez'),'Rebozo de algodón natural','Rosa Hernández','Telar de cintura','Chiapas',198000,'/images/textile-1.jpg',
  'Rebozo tejido en telar de cintura, con rapacejo anudado a mano.','Telar de cintura','Algodón natural','2.2 m × 70 cm',3,'stock_simple','publicado',false,false, now()-interval '12 days'),
 ('tel-03',(select id from public.artesanos where slug='coop-vida-nueva'),'Camino de mesa teñido con grana','Cooperativa Vida Nueva','Telar de cintura','Oaxaca',89000,'/images/textile-2.jpg',
  'Camino de mesa tejido con tintes naturales de grana cochinilla y añil.','Telar de cintura, tinte natural','Lana teñida con grana y añil','1.4 m × 40 cm',4,'stock_simple','publicado',false,true, now()-interval '8 days'),
 ('tel-04',(select id from public.artesanos where slug='coop-vida-nueva'),'Tapete de lana, tinte de añil','Cooperativa Vida Nueva','Telar de cintura','Oaxaca',165000,'/images/textile-2.jpg',
  'Tapete de lana teñida con añil natural, tejido en telar con motivos geométricos zapotecos.','Telar de pie, tinte natural','Lana teñida con añil','1.8 m × 1.2 m',4,'stock_simple','publicado',false,false, now()-interval '2 days'),
 ('ces-01',(select id from public.artesanos where slug='coop-tenango'),'Cesta de palma «Tenango»','Cooperativa Tenango','Cestería','Hidalgo',98000,'/images/handicraft-1.jpg',
  'Cesta tejida en palma con patrones geométricos, ideal para guardar o decorar.','Tejido en palma','Palma natural','30 × 25 cm',5,'stock_simple','publicado',false,false, now()-interval '1 days'),
 ('ces-02',(select id from public.artesanos where slug='coop-tenango'),'Canasta grande de asas','Cooperativa Tenango','Cestería','Hidalgo',115000,'/images/handicraft-2.jpg',
  'Canasta grande de palma con asas, tejido firme para uso diario.','Tejido en palma','Palma natural','40 × 35 cm',5,'stock_simple','publicado',false,false, now()-interval '18 days');

-- ---- Una variante por pieza (opciones {}) ----
insert into public.producto_variantes (producto_id, sku, opciones, activa)
select id, id || '-v', '{}'::jsonb, true from public.productos
where id like any (array['tal-%','bar-%','ale-%','tel-%','ces-%']);

-- ---- Inventario (unico=1; stock_simple con existencias; ces-02 agotado=0) ----
-- `disponible` es columna GENERADA (stock - reservado): no se inserta.
insert into public.inventario (variante_id, stock, reservado)
select pv.id, s.stock, 0
from public.producto_variantes pv
join (values
  ('tal-01',8),('tal-02',6),('tal-03',12),('bar-01',1),('bar-02',2),('bar-03',1),
  ('ale-01',1),('ale-02',1),('tel-01',4),('tel-02',5),('tel-03',12),('tel-04',4),
  ('ces-01',10),('ces-02',0)
) as s(pid, stock) on s.pid = pv.producto_id
where pv.sku = pv.producto_id || '-v';
