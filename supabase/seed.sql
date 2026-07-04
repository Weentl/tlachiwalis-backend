-- Tlachiwalis — seed de datos de prueba (artesanos + piezas del catálogo actual).
-- Ejecutar DESPUÉS de 0001_init.sql.

insert into public.artesanos (slug, nombre, region, oficio) values
  ('talavera-hnos',   'Talavera Hnos.',   'Puebla',          'Talavera'),
  ('macrina-pacheco', 'Macrina Pacheco',  'Oaxaca',          'Barro negro'),
  ('familia-ortega',  'Familia Ortega',   'Oaxaca',          'Alebrijes'),
  ('rosa-hernandez',  'Rosa Hernández',   'Chiapas',         'Telar de cintura'),
  ('taller-coyotepec','Taller Coyotepec', 'Oaxaca',          'Barro negro'),
  ('coop-vida-nueva', 'Coop. Vida Nueva', 'Oaxaca',          'Telar de cintura'),
  ('coop-tenango',    'Coop. Tenango',    'Hidalgo',         'Cestería'),
  ('taller-linares',  'Taller Linares',   'Edo. de México',  'Barro negro')
on conflict (slug) do nothing;

insert into public.productos
  (id, artesano_id, nombre, maker, oficio, region, precio_centavos, imagen, descripcion, tecnica, materiales, medidas)
select v.id, a.id, v.nombre, v.maker, v.oficio, v.region, v.precio_centavos, v.imagen,
       v.descripcion, v.tecnica, v.materiales, v.medidas
from (values
  ('tal-01','talavera-hnos','Plato de Talavera','Talavera Hnos.','Talavera','Puebla',129000,'/images/talavera-1.jpg','Plato decorativo de Talavera poblana, esmaltado y pintado a mano con motivos tradicionales en azul cobalto sobre fondo blanco.','Mayólica esmaltada, alta temperatura','Barro de Puebla, esmaltes minerales','28 cm de diámetro'),
  ('bar-01','macrina-pacheco','Olla de barro bruñido','Macrina Pacheco','Barro negro','Oaxaca',185000,'/images/pottery-1.jpg','Olla de barro negro bruñido de San Bartolo Coyotepec, pulida con cuarzo hasta lograr su brillo característico.','Barro negro bruñido, horno de leña','Arcilla negra de Oaxaca','22 × 20 cm'),
  ('ale-01','familia-ortega','Alebrije jaguar','Familia Ortega','Alebrijes','Oaxaca',340000,'/images/alebrije-1.jpg','Alebrije tallado en copal y pintado a mano con grecas y puntillismo zapoteco. Pieza única.','Talla en copal, pintura a pincel fino','Madera de copal','32 cm de largo'),
  ('tel-01','rosa-hernandez','Huipil de telar de cintura','Rosa Hernández','Telar de cintura','Chiapas',260000,'/images/huipil-1.jpg','Huipil tejido en telar de cintura por manos tzotziles de Zinacantán, con brocados florales.','Telar de cintura, brocado a mano','Algodón y lana teñidos','Talla única'),
  ('tal-02','talavera-hnos','Jarra de Talavera','Talavera Hnos.','Talavera','Puebla',164000,'/images/talavera-2.jpg','Jarra de Talavera para agua o flores, vidriada y decorada a mano.','Mayólica esmaltada','Barro de Puebla, esmaltes minerales','26 cm de alto'),
  ('bar-02','taller-coyotepec','Cántaro de barro negro','Taller Coyotepec','Barro negro','Oaxaca',142000,'/images/pottery-2.jpg','Cántaro de barro negro mate, modelado a mano con formas tradicionales oaxaqueñas.','Barro negro, modelado a mano','Arcilla negra de Oaxaca','30 × 18 cm'),
  ('ale-02','familia-ortega','Alebrije venado','Familia Ortega','Alebrijes','Oaxaca',298000,'/images/alebrije-2.jpg','Venado alebrije en copal, con cornamenta tallada y decoración policroma.','Talla en copal, pintura a pincel','Madera de copal','26 cm de alto'),
  ('tel-02','rosa-hernandez','Rebozo de algodón','Rosa Hernández','Telar de cintura','Chiapas',198000,'/images/textile-1.jpg','Rebozo tejido en telar de cintura, con rapacejo anudado a mano.','Telar de cintura','Algodón natural','2.2 m × 70 cm'),
  ('tel-03','coop-vida-nueva','Camino de mesa tejido','Coop. Vida Nueva','Telar de cintura','Oaxaca',89000,'/images/textile-2.jpg','Camino de mesa tejido por mujeres zapotecas, teñido con tintes naturales.','Telar de cintura, tinte natural','Lana teñida con grana y añil','1.4 m × 40 cm'),
  ('ces-01','coop-tenango','Cesta de palma tejida','Coop. Tenango','Cestería','Hidalgo',98000,'/images/handicraft-1.jpg','Cesta tejida en palma con patrones geométricos, ideal para guardar o decorar.','Tejido en palma','Palma natural','30 × 25 cm'),
  ('ces-02','coop-tenango','Canasta tejida grande','Coop. Tenango','Cestería','Hidalgo',115000,'/images/handicraft-2.jpg','Canasta grande de palma con asas, tejido firme para uso diario.','Tejido en palma','Palma natural','40 × 35 cm'),
  ('bar-03','taller-linares','Catrina de barro','Taller Linares','Barro negro','Edo. de México',220000,'/images/catrina-1.jpg','Catrina modelada en barro y pintada a mano, homenaje a la tradición del Día de Muertos.','Modelado en barro, pintura a mano','Barro y pigmentos','38 cm de alto')
) as v(id, artesano_slug, nombre, maker, oficio, region, precio_centavos, imagen, descripcion, tecnica, materiales, medidas)
left join public.artesanos a on a.slug = v.artesano_slug
on conflict (id) do nothing;
