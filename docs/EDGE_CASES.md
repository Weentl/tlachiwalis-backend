# Tlachiwalis — Catálogo de Edge Cases del Panel Admin

> 132 casos identificados across 8 dominios (DB, RLS, backend, idempotencia, frontend, fiscal, storage, catálogos), cada uno con solución e idempotencia. Generado por un workflow multi-agente y consolidado.

## Resumen por dominio

| Dominio | Casos | 🔴 Alta | 🟡 Media | 🟢 Baja | A implementar ya |
|---|---|---|---|---|---|
| Base de datos / esquema | 16 | 7 | 8 | 1 | 9 |
| Seguridad / RLS / authz | 17 | 7 | 7 | 3 | 11 |
| Backend / Server Actions | 18 | 7 | 9 | 2 | 10 |
| Idempotencia / concurrencia | 16 | 7 | 7 | 2 | 6 |
| Frontend / UX | 17 | 7 | 9 | 1 | 11 |
| Fiscal / negocio (MX) | 16 | 7 | 7 | 2 | 8 |
| Storage / imágenes | 15 | 6 | 7 | 2 | 11 |
| Catálogos / datos pre-rellenados | 17 | 5 | 7 | 5 | 11 |
| **Total** | **132** | **53** | **61** | **18** | **77** |


## Base de datos / esquema

### 1. 🔴 Alta · **⚡ implementar ya**
**Escenario.** El admin elimina al artesano 'familia-ortega' desde /admin/artesanos. Tiene ale-01 y ale-02 con status='publicado'. eliminarArtesano hace DELETE en artesanos; la FK productos.artesano_id es ON DELETE SET NULL.

**Problema.** ale-01/ale-02 quedan con artesano_id=NULL pero status sigue 'publicado'. La policy productos_publicados_select solo filtra por status, no por artesano_id, así que las piezas siguen visibles al público (getProducts las devuelve). Quedan piezas 'huérfanas' vendiéndose sin dueño fiscal: no hay RFC/CLABE para retener ni dispersar. El dashboard las cuenta en GMV bajo topArtesanos label 'Sin asignar'.

**Solución.** Decidir política explícita en vez de heredar SET NULL silencioso. Opción recomendada para MVP: en eliminarArtesano, dentro de la misma operación, despublicar las piezas antes de borrar: `await supabase.from('productos').update({ status: 'borrador' }).eq('artesano_id', id)` y luego delete del artesano (queda artesano_id NULL pero ya no público). Mejor aún a nivel BD: añadir un trigger BEFORE DELETE on artesanos que ponga status='borrador' a sus productos, o cambiar la FK a ON DELETE RESTRICT y forzar al admin a reasignar/despublicar primero (UX: el botón Eliminar muestra 'tiene N piezas, reasígnalas o despublícalas'). RESTRICT es lo más seguro fiscalmente. Migración 0004: `alter table productos drop constraint productos_artesano_id_fkey, add constraint productos_artesano_id_fkey foreign key (artesano_id) references artesanos(id) on delete restrict;`

**Idempotencia/seguridad.** El UPDATE de despublicar es naturalmente idempotente (correrlo dos veces deja el mismo estado). Con RESTRICT, un segundo DELETE tras reasignar simplemente borra; un DELETE sobre id ya borrado afecta 0 filas sin error. No hay doble efecto.

### 2. 🔴 Alta · **⚡ implementar ya**
**Escenario.** El artesano 'Talavera Hnos.' cambia de nombre comercial a 'Talavera Poblana SA'. El admin edita artesanos.nombre vía actualizarArtesano. tal-01 y tal-02 tienen maker='Talavera Hnos.' (denormalizado en seed/insert).

**Problema.** maker en productos NO se actualiza: la tienda pública sigue mostrando 'Talavera Hnos.' en tal-01/tal-02 mientras el panel muestra 'Talavera Poblana SA'. Inconsistencia permanente entre artesanos.nombre y productos.maker. Lo mismo al crear producto: producto-form no autocompleta maker desde el artesano elegido, así que el admin puede teclear un maker que no coincide con ningún artesano.

**Solución.** Tratar maker como cache derivada, no como fuente de verdad. (a) En actualizarArtesano, tras el update propagar: `await supabase.from('productos').update({ maker: parsed.data.nombre }).eq('artesano_id', id)`. (b) En crearProducto/actualizarProducto, si artesano_id viene, derivar maker del artesano en el servidor en vez de confiar en el campo del form: leer nombre del artesano y usarlo (ignorar el maker del cliente cuando hay artesano_id, conservándolo solo para piezas 'sin asignar'). A futuro, evaluar dropear maker y servir el nombre vía JOIN/vista pública, eliminando la denormalización.

**Idempotencia/seguridad.** Los UPDATE de propagación son idempotentes por valor. Si dos ediciones concurrentes del mismo artesano corren, el último writer gana de forma consistente tanto en artesanos.nombre como en productos.maker (misma transacción lógica recomendada).

### 3. 🔴 Alta · **⚡ implementar ya**
**Escenario.** Dos pestañas del admin crean en paralelo dos productos distintos usando el mismo slug 'tal-03' en el campo id (PK text). O el admin reusa el id de una pieza recién borrada.

**Problema.** PK garantiza unicidad: el segundo insert falla con duplicate key. crearProducto ya mapea 'duplicate' → 'Ya existe una pieza con ese identificador', lo cual es correcto. PERO el orden del código sube la imagen ANTES del insert: en la colisión, la imagen ya quedó en el bucket 'piezas' y nunca se referencia → archivo huérfano en storage. Mismo problema si el insert falla por cualquier constraint (precio, etc.).

**Solución.** Reordenar: validar e intentar el insert de la fila primero con imagen=null, y solo si tiene éxito subir la imagen y hacer un UPDATE con la URL; o subir la imagen y, en el catch del insert duplicado/erróneo, borrar el objeto recién subido: `await supabase.storage.from('piezas').remove([path])`. La PK ya da la idempotencia de la fila; falta limpiar el efecto colateral en storage. Mantener el path con crypto.randomUUID() evita además colisión de nombres de archivo.

**Idempotencia/seguridad.** El reintento del usuario tras el error de duplicado es seguro a nivel fila (PK lo bloquea). La limpieza del objeto en storage debe hacerse en el path de error para que reintentar no acumule basura. remove() de un path inexistente no es fatal.

### 4. 🟡 Media · **⚡ implementar ya**
**Escenario.** El admin cambia el slug de un artesano de 'talavera-hnos' a 'talavera-poblana' vía actualizarArtesano (slug está en el whitelist editable). El slug del artesano se usa en su URL pública /artesanos/[slug] y como join key del seed (a.slug = v.artesano_slug).

**Problema.** Cambiar artesanos.slug rompe cualquier enlace externo/SEO a la página del artesano y desincroniza con datos sembrados por slug. No hay redirección. Además artesanos.slug es UNIQUE not null: si el admin teclea un slug ya tomado por otro artesano, el update falla con duplicate, pero el mensaje genérico ('No se pudo guardar: ...') no aclara que es colisión de slug (a diferencia del create, que sí traduce 'duplicate').

**Solución.** (a) Traducir el error de unicidad también en actualizarArtesano: `error.message.includes('duplicate') ? 'Ya existe un artesano con ese slug.' : ...`. (b) Decidir si slug es inmutable post-creación (como el id de producto, que el form marca readOnly 'No se puede cambiar después'). Si debe ser editable, registrar el slug viejo para redirect 301; si no, sacar slug del schema de update o marcarlo readOnly en artesano-form. Recomendado para MVP: slug inmutable, consistente con productos.id.

**Idempotencia/seguridad.** El UNIQUE en BD es el respaldo real ante doble submit concurrente: dos updates al mismo slug nuevo → uno gana, el otro recibe duplicate. n/a para idempotencia más allá de eso.

### 5. 🔴 Alta
**Escenario.** El admin captura la región como 'Oaxaca ' (con espacio final), otra pieza como 'oaxaca', otra como 'OAXACA', y el oficio como 'Barro negro' vs 'Barro Negro'. region/oficio en productos son text libre, sin tabla canónica ni normalización más allá del .trim() de zod en productoBaseSchema.

**Problema.** El .trim() de zod quita espacios extremos pero NO normaliza mayúsculas/acentos. El filtro público por oficio (getOficios hace Set sobre p.oficio crudo) y las agregaciones del dashboard (porOficio, porRegion implícito) fragmentan: 'Barro negro' y 'Barro Negro' aparecen como dos categorías, el filtro de la tienda muestra duplicados, y el GMV por oficio se reparte mal.

**Solución.** Introducir vocabulario controlado. MVP barato: tablas catálogo public.oficios(slug pk, nombre) y public.regiones(slug pk, nombre) sembradas con los valores reales del seed (Talavera, Barro negro, Alebrijes, Telar de cintura, Cestería / Puebla, Oaxaca, Chiapas, Hidalgo, Edo. de México), y en producto-form/artesano-form usar SelectField en vez de TextField libre para oficio/region. A nivel BD, añadir CHECK o FK a esas tablas. Si se quiere seguir con text por ahora, al menos normalizar en el servidor (lower + trim) en una columna generada para agrupar, manteniendo el display original.

**Idempotencia/seguridad.** n/a (es validación/normalización de entrada, no operación reintetable con efecto monetario).

### 6. 🟡 Media · **⚡ implementar ya**
**Escenario.** Un cliente malicioso o un bug de form envía precio_pesos = -50, o 0, o 3.5 (con centavos), o 'abc', o 999999999 directamente al Server Action crearProducto (las Server Actions son endpoints POST públicos alcanzables sin pasar por el form).

**Problema.** El CHECK de BD es solo precio_centavos >= 0, así que un 0 pasaría la BD. La defensa real está en zod: .int (rechaza 3.5), .positive (rechaza 0 y negativos), .max(10_000_000) (rechaza desbordes), coerce.number (rechaza 'abc'). Está bien cubierto en app. El hueco es la divergencia: si alguien sube el .max de zod o inserta por otra vía, precio_centavos = precio_pesos*100 con 10_000_000 → 1,000,000,000 centavos cabe en int4 (max 2,147,483,647), pero un valor mayor desbordaría int4 con error de BD poco claro.

**Solución.** Alinear el CHECK de BD con la regla de negocio real, defensa en profundidad bajo zod: `alter table productos drop constraint productos_precio_centavos_check, add constraint productos_precio_centavos_check check (precio_centavos > 0 and precio_centavos <= 1000000000);` (precio > 0, no solo >= 0, y techo que evita overflow de int4). Así, aunque la validación de app falle o cambie, la BD rechaza 0, negativos y desbordes. Mantener zod como primera línea con mensajes amigables.

**Idempotencia/seguridad.** n/a (validación). El CHECK es determinista: el mismo insert rechazado se rechaza igual en reintento.

### 7. 🟡 Media · **⚡ implementar ya**
**Escenario.** El admin asigna en producto-form un artesano vía el dropdown, pero entre que cargó el form y envió, otro admin (o él mismo en otra pestaña) eliminó ese artesano. crearProducto/actualizarProducto envían artesano_id = '<uuid-borrado>'.

**Problema.** La FK productos.artesano_id references artesanos(id) rechaza el insert/update con foreign_key_violation. crearProducto y actualizarProducto solo traducen 'duplicate'; un error de FK cae en el ramo genérico 'No se pudo crear/guardar: insert or update on table ... violates foreign key constraint', mensaje técnico filtrado al usuario y poco accionable.

**Solución.** Capturar el error de FK y traducirlo: `error.message.includes('foreign key') || error.code === '23503' ? 'El artesano seleccionado ya no existe; vuelve a elegir uno.' : ...`. Además, refrescar la lista de opciones del form en el render (ya viene de listarArtesanosOpciones por request, así que tras revalidatePath se actualiza). La FK ya garantiza integridad referencial en la escritura; solo falta UX.

**Idempotencia/seguridad.** El FK constraint es el respaldo: ningún producto puede quedar apuntando a un artesano inexistente, sin importar reintentos. n/a adicional.

### 8. 🔴 Alta
**Escenario.** El admin sube imagen a tal-01, luego edita tal-01 y sube una imagen nueva (actualizarProducto reemplaza row.imagen con la nueva URL). Después elimina tal-01 con eliminarProducto. También elimina un artesano que tenía foto_url apuntando al bucket.

**Problema.** eliminarProducto solo hace delete de la fila; NUNCA borra el objeto en storage al que apuntaba productos.imagen. actualizarProducto al subir nueva imagen tampoco borra la anterior. eliminarArtesano no toca foto_url. Resultado: archivos huérfanos acumulándose indefinidamente en el bucket 'piezas' público, sin fila que los referencie (no hay forma de saber cuáles son basura sin un barrido). Crece costo y superficie.

**Solución.** En eliminarProducto, antes/después del delete de fila, leer la fila para obtener imagen, extraer el path relativo (todo tras '/piezas/') y `supabase.storage.from('piezas').remove([path])`. En actualizarProducto, si se sube nueva imagen y había una previa en el bucket, remover la previa tras el update exitoso. Para artesanos con foto en el bucket, igual. Como red de seguridad a futuro: job/función SQL que liste storage.objects del bucket sin match en productos.imagen/artesanos.foto_url y los borre (GC). No bloqueante para MVP pero la fuga es real.

**Idempotencia/seguridad.** remove() es idempotente: borrar un objeto ya inexistente no es fatal. Hacer la limpieza después de confirmar el delete/update de fila evita borrar la imagen de una operación que falló. Reintentos seguros.

### 9. 🟡 Media
**Escenario.** Dos pestañas del admin abren editar para el mismo producto tal-01. Pestaña A cambia el precio a 1500 y guarda; pestaña B (cargada antes) cambia status a 'agotado' y guarda 30s después con el precio viejo 1290.

**Problema.** actualizarProducto hace un UPDATE completo del row (toRow incluye TODOS los campos), no un patch parcial. El guardado de B sobrescribe el precio nuevo de A con el viejo 1290 (last-write-wins ciego). Se pierde la edición de A sin aviso. El trigger touch_updated_at refresca updated_at pero nadie lo usa para detectar conflicto.

**Solución.** Optimistic concurrency con updated_at: el form lleva un hidden con el updated_at cargado; el UPDATE incluye `.eq('updated_at', updatedAtOriginal)`. Si afecta 0 filas, alguien escribió antes → devolver 'Otro usuario modificó esta pieza; recarga y reintenta'. Verificar count: `const { data, error, count } = await supabase.from('productos').update(row, { count: 'exact' }).eq('id', id).eq('updated_at', orig).select()`. Alternativa más simple para 1-2 admins: aceptar last-write-wins explícitamente y documentarlo.

**Idempotencia/seguridad.** El check de updated_at convierte la operación en condicional: un doble submit del MISMO form (mismo updated_at base) aplica una vez; el segundo encuentra updated_at ya cambiado por el trigger y afecta 0 filas → no duplica ni revierte. Es la idempotencia que pide CLAUDE.md respaldada por estado en BD.

### 10. 🟡 Media
**Escenario.** Reportes y filtros: el dashboard agrupa topArtesanos por productos.artesano_id, pero existen piezas con artesano_id NULL (huérfanas tras borrado, o 'Sin asignar' al crear). El público filtra/ordena el catálogo y lista oficios. La tabla productos tiene índices en oficio, region, status, artesano_id.

**Problema.** Los índices existentes cubren los filtros públicos (status='publicado' + oficio/region) y el FK lookup. PERO no hay índice para la consulta pública real combinada `where status='publicado' order by created_at`, que escanea y ordena; con catálogo chico no duele, pero el order by created_at sin índice se nota al crecer. Tampoco hay índice en artesanos.status (la vista artesanos_publicos filtra status='activo'). Y artesano_id NULL en productos_artesano_idx infla el índice con NULLs que el FK no necesita.

**Solución.** Añadir índices alineados a las queries reales: `create index productos_publicados_orden_idx on productos (created_at) where status='publicado';` (índice parcial para la lista pública). `create index artesanos_status_idx on artesanos (status);` para la vista pública. Convertir productos_artesano_idx en parcial para excluir NULLs: `create index productos_artesano_idx on productos (artesano_id) where artesano_id is not null;` (solo sirve para joins, los NULL nunca se joinean). Revisar con EXPLAIN antes de añadir; con datos chicos puede no valer la pena aún.

**Idempotencia/seguridad.** create index if not exists / drop+create en migración versionada es idempotente. Usar concurrently en prod para no bloquear. n/a monetario.

### 11. 🔴 Alta · **⚡ implementar ya**
**Escenario.** El admin pausa un artesano (status='pausado') que tiene piezas publicadas (ej. pausa 'rosa-hernandez' con tel-01, tel-02 en 'publicado').

**Problema.** artesanos.status='pausado' saca al artesano de artesanos_publicos (la vista filtra status='activo'), pero sus productos siguen con status='publicado' y la policy productos_publicados_select los muestra igual. Resultado incoherente: las piezas se venden públicamente pero su artesano no aparece como activo; la página del artesano /artesanos/[slug] da 404 (no está en la vista) mientras sus piezas siguen comprables. No hay regla que ligue status del artesano con visibilidad de sus piezas.

**Solución.** Definir y aplicar la regla de negocio: pausar un artesano debe ocultar sus piezas del público. En actualizarArtesano, si status pasa a 'pausado', despublicar sus piezas: `await supabase.from('productos').update({ status: 'borrador' }).eq('artesano_id', id).eq('status','publicado')`; al reactivar, NO re-publicar automáticamente (que el admin decida). Alternativa a nivel lectura: cambiar la policy/vista pública de productos para exigir que el artesano esté activo (requiere que la policy de productos consulte artesanos, posible con una función SECURITY DEFINER artesano_activo(artesano_id)). La opción de despublicar en la escritura es más simple y predecible para el MVP.

**Idempotencia/seguridad.** El UPDATE condicionado a .eq('status','publicado') es idempotente: re-ejecutarlo no re-despublica lo ya en borrador ni toca agotados. Reintento seguro.

### 12. 🔴 Alta · **⚡ implementar ya**
**Escenario.** Despliegue de los cambios de schema (FK ON DELETE, CHECK de precio, índices, tablas catálogo). Las migraciones existentes son 0001/0002/0003, idempotentes (if not exists, drop policy if exists). El proyecto declara 'Migraciones de BD versionadas' como obligatorio.

**Problema.** Riesgo de aplicar cambios al esquema editando 0001 en lugar de crear 0004 (rompería el historial y la reproducibilidad). Cambiar la FK de SET NULL a RESTRICT fallaría si ya existen productos con artesano_id NULL (no, RESTRICT no mira filas existentes) pero un cambio a NOT NULL sí fallaría con huérfanos presentes. Un CHECK nuevo de precio > 0 falla si ya hay alguna fila con precio_centavos = 0.

**Solución.** Crear migración nueva 0004_integridad.sql, nunca editar las aplicadas. Antes de añadir constraints más estrictos, sanear datos en la misma migración: para el CHECK precio>0, primero `update productos set status='borrador' where precio_centavos = 0` o corregir; para NOT NULL en artesano_id (si se decidiera), primero resolver huérfanos. Envolver DDL+saneo en una transacción. Para FK RESTRICT: drop+add constraint con el mismo nombre, idempotente vía `if exists`. Validar la migración en un branch de Supabase (mcp create_branch / apply_migration) antes de merge.

**Idempotencia/seguridad.** Las migraciones deben ser re-ejecutables: usar 'drop constraint if exists' antes de 'add', 'create index if not exists', 'insert ... on conflict do nothing' para catálogos. Probar aplicar dos veces en branch. Es el patrón ya usado en 0002/0003.

### 13. 🟡 Media
**Escenario.** Modelo de borrado: hoy todo es hard-delete (eliminarArtesano/eliminarProducto hacen DELETE físico). Más adelante existirá módulo de órdenes/pagos que necesitará referenciar productos y artesanos vendidos para CFDI, retenciones y dispersión histórica.

**Problema.** Borrar físicamente un producto o artesano que ya tuvo ventas (en la fase futura) destruiría la trazabilidad fiscal: una orden pagada apuntaría a un producto/artesano inexistente, imposibilitando reemitir un CFDI o auditar una retención. El SET NULL actual ya anticipa parte del problema en productos, pero el hard-delete del artesano elimina rfc/regimen/clabe necesarios para el histórico de retenciones.

**Solución.** Adoptar soft-delete para entidades con implicación fiscal antes de construir órdenes. Añadir `deleted_at timestamptz null` a artesanos y productos; eliminarX hace `update ... set deleted_at = now()` en vez de delete; las queries públicas/admin filtran deleted_at is null; la vista artesanos_publicos añade `and deleted_at is null`. Las futuras órdenes referencian la fila que sigue existiendo. Para el MVP actual (sin órdenes) el hard-delete es tolerable, pero conviene introducir deleted_at ya para no migrar datos vivos después. Documentar como decisión de diseño.

**Idempotencia/seguridad.** El soft-delete es idempotente: re-marcar deleted_at sobre una fila ya borrada no cambia el resultado observable (sigue filtrada). Evita además el problema de 'reusar el id de una pieza borrada' porque la PK sigue ocupada.

### 14. 🟡 Media
**Escenario.** El admin captura un RFC o CLABE con formato válido para zod pero semánticamente erróneo: CLABE de 18 dígitos que NO pasa el dígito verificador (módulo 10 ponderado), o RFC que cumple el regex pero no corresponde a una persona real. clabe/rfc son sensibles y la CLABE se usará para dispersar dinero real.

**Problema.** zod valida solo forma: rfc con regex de estructura, clabe con /^\d{18}$/. Una CLABE con un dígito tecleado mal pasa la validación pero, en la fase de dispersión, enviaría el neto del artesano a una cuenta equivocada o sería rechazada por el banco. No hay validación de checksum ni unicidad (dos artesanos podrían tener la misma CLABE por error de copy-paste).

**Solución.** (a) Añadir validación de dígito control de CLABE en zod (.refine con el algoritmo módulo 10 ponderado 3-7-1 sobre los 17 primeros dígitos vs el 18). (b) Considerar UNIQUE parcial para evitar CLABE/RFC duplicados por error: `create unique index artesanos_clabe_uniq on artesanos (clabe) where clabe is not null;` y similar para rfc (con normalización a mayúsculas previa). (c) Confirmar con contador antes de operar dispersión. No mover dinero hasta validar. Mantener estos campos fuera de cualquier respuesta pública (ya cubierto por la vista y RLS).

**Idempotencia/seguridad.** El UNIQUE index es el respaldo en BD ante doble alta concurrente de la misma CLABE. La validación de checksum es determinista. n/a monetario en esta fase (sin dispersión aún).

### 15. 🟡 Media · **⚡ implementar ya**
**Escenario.** Coherencia de NULLs y defaults al crear: producto-form default status='borrador' pero el form de crear no fuerza imagen ni artesano. Se crea tal-04 con artesano_id NULL, imagen NULL, maker NULL, status='borrador'. Luego se publica directo a 'publicado' sin asignar artesano ni imagen.

**Problema.** Una pieza publicada sin artesano_id (sin dueño fiscal) y/o sin imagen llega al catálogo público: getProducts mapea imagen NULL a '' (img vacío → posible imagen rota en la tienda) y maker NULL a '' (pieza sin atribución de taller). No hay constraint que impida publicar algo incompleto. Riesgo de publicar piezas a medio capturar.

**Solución.** Validación condicional por status en el servidor: si status='publicado', exigir artesano_id, imagen y maker no nulos (superRefine en zod cuando status==='publicado', o un CHECK en BD: `check (status <> 'publicado' or (artesano_id is not null and imagen is not null))`). Mensaje de UX: 'Para publicar, asigna artesano e imagen'. Mantener borrador permisivo. Esto cierra el hueco de publicar huérfanos por descuido y se complementa con el caso del borrado de artesano.

**Idempotencia/seguridad.** El CHECK condicional es determinista e idempotente: el mismo intento de publicar incompleto se rechaza igual en cada reintento, sin estado parcial. n/a monetario.

### 16. 🟢 Baja
**Escenario.** El admin captura semblanza/descripcion/historia del artesano con HTML o caracteres especiales (ej. pega texto con <script>, o comillas, o un apóstrofo en 'Hernández'). Estos campos son text libre y se renderizan en la tienda pública.

**Problema.** A nivel BD no hay riesgo de SQL injection (el cliente de Supabase parametriza). El riesgo es XSS almacenado si la tienda renderiza descripcion/semblanza con dangerouslySetInnerHTML o sin escapar. Por ahora React escapa por defecto, pero el dato sucio queda persistido y un futuro render como HTML lo activaría. CLAUDE.md exige sanitizar HTML de usuario.

**Solución.** Sanitizar/normalizar en el servidor al guardar: para MVP, dado que el render es texto plano, basta con asegurar que NUNCA se use dangerouslySetInnerHTML con estos campos. Si se quiere permitir formato, sanitizar con una allowlist (ej. sanitize-html) en el Server Action antes del insert/update, no al renderizar. Documentar que descripcion/semblanza son texto plano. No es un problema de BD per se pero el dato vive en BD.

**Idempotencia/seguridad.** Sanitizar es idempotente solo si se hace sobre la entrada cruda cada vez (sanitizar dos veces un texto ya limpio no lo daña con una librería estándar). n/a monetario.


## Seguridad / RLS / authz

### 17. 🔴 Alta · **⚡ implementar ya**
**Escenario.** La vista public.artesanos_publicos (0001_init.sql L61-66) se crea SIN `with (security_invoker = on)`. Cualquiera con la anon key (curl directo a /rest/v1/artesanos_publicos) la lee.

**Problema.** En Postgres una vista corre con los permisos del DUEÑO (el rol que la creó, normalmente postgres/supabase_admin que bypassa RLS). La vista es hoy el ÚNICO filtro de datos fiscales: si alguien añade una columna sensible al SELECT, o si se hace `select *`, se filtran rfc/regimen_fiscal/clabe sin que RLS lo impida. Además, con security_invoker OFF la RLS de la tabla base artesanos NO se evalúa para el llamante, así que la seguridad depende 100% de recordar excluir columnas a mano en cada cambio de la vista. Es exactamente el footgun que Supabase advisor marca como `security_definer_view`.

**Solución.** Recrear la vista con invoker y blindar columnas: `create or replace view public.artesanos_publicos with (security_invoker = on, security_barrier = true) as select id, slug, nombre, semblanza, region, oficio, foto_url from public.artesanos where status = 'activo';`. Con security_invoker=on la RLS del que consulta SÍ aplica, por lo que se necesita además una policy SELECT mínima para anon sobre la tabla base que NO exponga columnas (RLS es por fila, no por columna, así que se mantiene la vista como capa de columnas + revoke select sobre la tabla base a anon, que ya no la tiene). Verificar con `supabase get_advisors` que desaparezca security_definer_view. Probar: `select rfc from artesanos_publicos` debe fallar por columna inexistente, no devolver dato.

**Idempotencia/seguridad.** n/a (DDL idempotente vía create or replace; ejecutable múltiples veces sin efecto adicional).

### 18. 🔴 Alta · **⚡ implementar ya**
**Escenario.** Self-hosted por HTTP sobre Tailscale (sin TLS). El login (admin/login/actions.ts) emite cookies de sesión GoTrue (sb-access-token / sb-refresh-token) que viajan en texto plano por la red Tailscale.

**Problema.** Sin el flag `Secure` y sin TLS, un atacante en la ruta (otro nodo Tailscale comprometido, MITM en la LAN del admin, o sniffing en el salto de salida) captura el refresh token y obtiene sesión admin persistente = control total del panel (lee rfc/clabe de todos los artesanos, cambia precios, borra catálogo). Tailscale cifra nodo-a-nodo pero la app NO marca las cookies como Secure, así que cualquier fallback a HTTP plano (o un proxy intermedio) las expone, y getUser()/getSession() las aceptan.

**Solución.** Terminar TLS antes de la app: poner Caddy/nginx con `tls internal` o un cert de Tailscale (`tailscale cert`) delante de Next, servir solo HTTPS. Forzar cookies Secure pasando cookieOptions al createServerClient en proxy.ts y admin-server.ts: `createServerClient(url, key, { cookieOptions: { secure: true, sameSite: 'lax', httpOnly: true, path: '/' }, cookies: {...} })`. Reducir TTL del access token en GoTrue (JWT_EXP corto) para acotar la ventana de robo. Mientras no haya TLS, NO operar con datos fiscales reales.

### 19. 🔴 Alta · **⚡ implementar ya**
**Escenario.** El login admin (iniciarSesion en admin/login/actions.ts) llama signInWithPassword sin ningún límite de intentos. No existe rate limiting en todo el repo (grep de rate-limit/throttle: cero resultados).

**Problema.** Brute-force de credenciales del único rol con acceso total. Con GoTrue self-hosted sin SMTP no hay MFA ni lockout por defecto; un script puede probar miles de contraseñas. Cada Server Action mutante (crearProducto, subirImagen) también es un endpoint POST público sin throttle: subir imágenes 5 MB en bucle agota disco/CPU del self-host.

**Solución.** Rate limit por IP+email en iniciarSesion antes de signInWithPassword. En self-host sin Redis externo, usar tabla Postgres: `create table auth_attempts(key text, window_start timestamptz, n int, primary key(key))` y un RPC SECURITY DEFINER que haga `insert ... on conflict (key) do update set n = case when now()-window_start > interval '15 min' then 1 else n+1 end ... returning n`; rechazar si n>5. Para Server Actions de escritura, un middleware ligero en proxy.ts que cuente POSTs a /admin/* por IP. Config GoTrue: `GOTRUE_RATE_LIMIT_*`. Stripe Radar no aplica (pagos diferidos).

**Idempotencia/seguridad.** El contador usa UPSERT atómico `on conflict do update`, seguro ante requests concurrentes (un solo INSERT gana, el resto incrementa sin race).

### 20. 🔴 Alta · **⚡ implementar ya**
**Escenario.** is_admin() (0002_admin_rls.sql) es SECURITY DEFINER y consulta public.admins. La policy admins_admin_write permite a un admin hacer INSERT/UPDATE/DELETE en admins (for all using/with check is_admin()).

**Problema.** Escalada/persistencia: cualquier admin puede insertarse a sí mismo o a un cómplice más como admin (auto-perpetuación, hay 0 separación entre 'admin operativo' y 'super-admin'). Peor: si un admin es comprometido vía robo de cookie (caso HTTP de arriba), el atacante inserta su propio user_id en admins y sobrevive aunque rote la contraseña del admin original. No hay auditoría de quién agregó a quién.

**Solución.** Quitar la escritura de admins de la RLS de la app: `drop policy admins_admin_write`. Gestionar el rol admin SOLO por psql/superusuario fuera de banda (como ya se siembra el primero). Si se necesita gestión en-app, separar roles: columna `admins.role in ('owner','staff')`, y policy de INSERT que exija `(select role from admins where user_id=auth.uid())='owner'` con `with check (role='staff')` (un staff nunca crea owners). Agregar tabla `admins_audit(actor uuid, action, target uuid, at timestamptz)` poblada por trigger. Mantener SELECT como está.

**Idempotencia/seguridad.** n/a (cambio de policy DDL idempotente). El UNIQUE de user_id (PK) ya evita duplicar un admin.

### 21. 🔴 Alta · **⚡ implementar ya**
**Escenario.** Server Actions del panel (crear/actualizar/eliminar Producto y Artesano) son endpoints POST. El proxy.ts solo valida `user` (getUser) y redirige si no hay sesión, pero NO verifica el header Origin, y next.config.ts no define `serverActions.allowedOrigins`.

**Problema.** CSRF en Server Actions. Next 16 protege Server Actions comparando Origin vs Host, pero en self-host detrás de proxy/Tailscale el Host visto por Next puede no coincidir con el dominio real (IP Tailscale vs hostname), forzando a relajar la verificación o rompiéndola silenciosamente. Si un admin con sesión viva visita una página maliciosa, esa página puede disparar un POST a /admin/productos/... y, como las cookies son SameSite por defecto pero podrían enviarse en navegación top-level, ejecutar acciones mutantes (borrar catálogo, cambiar precios a $1).

**Solución.** Declarar explícitamente el origen permitido: en next.config.ts `experimental: { serverActions: { allowedOrigins: ['tlachiwalis.tu-tailnet.ts.net', 'tu-ip:3000'] } }` con el host EXACTO por el que entra el admin. Confirmar SameSite=Lax/Strict en cookieOptions (ver caso HTTP). Mantener requireAdmin() en cada action (ya está) como defensa en profundidad — pero el CSRF roba la sesión válida del admin, así que requireAdmin no basta: la verificación de Origin es la que corta el ataque.

### 22. 🔴 Alta · **⚡ implementar ya**
**Escenario.** actualizarProducto (productos/actions.ts L92-122) toma `id` de formData crudo y ejecuta `.update(row).eq('id', id)` sin validar que id sea un slug existente ni que el PK no se intente reasignar; toRow no incluye id, pero el id objetivo viene del cliente.

**Problema.** IDOR limitado: aunque RLS exige is_admin() para el UPDATE (así que un no-admin no pasa), un admin legítimo es la única barrera y el id no se valida contra el regex de slug (productoCrearSchema usa `slug`, pero el UPDATE usa `String(formData.get('id'))` sin schema). Un id arbitrario (espacios, mayúsculas, inyección de caracteres) llega tal cual al filtro. No causa fuga (RLS), pero permite updates a-ciegas y rompe la invariante de que id == slug válido. Mismo patrón en eliminarProducto y eliminar/actualizarArtesano.

**Solución.** Validar el id objetivo con el mismo `slug` zod antes de tocar la BD: `const idParse = slug.safeParse(formData.get('id')); if(!idParse.success) return {message:'id inválido'}`. Para artesanos validar UUID con el mismo regex que artesano_id ya usa en schemas.ts. Confirmar que `.maybeSingle()`/conteo de filas afectadas > 0 para detectar updates a id inexistente y devolver error en vez de éxito silencioso.

**Idempotencia/seguridad.** El UPDATE por PK es idempotente por naturaleza (re-ejecutar deja la misma fila). Validar id evita updates accidentales a la fila equivocada en reintentos.

### 23. 🔴 Alta · **⚡ implementar ya**
**Escenario.** La policy anon de productos (productos_publicados_select, 0001 L54) permite SELECT a anon/authenticated cuando status='publicado'. El catálogo público (catalog.ts) filtra además status='publicado'. Pero un producto en 'borrador' o 'agotado' que estuvo 'publicado' queda cacheado por ISR/revalidatePath.

**Problema.** Acceso anon a borradores/agotados vía caché. revalidatePath('/tienda/:id') se llama en actualizarProducto, pero si un admin pone un producto en 'borrador' la página /tienda/[id] cacheada puede seguir sirviéndose hasta que expire, exponiendo una pieza despublicada (precio viejo, descripción no lista) a anónimos. Y getProduct() (catalog.ts L40) busca dentro de getProducts() que SÍ filtra publicado — bien — pero la ruta dinámica cacheada es el hueco.

**Solución.** Garantizar invalidación al despublicar: en actualizarProducto, SIEMPRE revalidar la ruta del producto y la lista aunque cambie a borrador (ya se hace revalidatePath(`/tienda/${id}`) — verificar que el id usado sea el correcto y que la página /tienda/[id] devuelva 404 cuando getProduct no lo encuentra, no una versión stale). A nivel RLS está correcto (anon nunca lee borrador por REST). Reforzar: la página de producto debe llamar notFound() si getProduct devuelve undefined, y considerar `export const dynamic = 'force-dynamic'` o tags de caché por id para invalidación precisa.

**Idempotencia/seguridad.** n/a (lectura). revalidatePath es idempotente.

### 24. 🟡 Media · **⚡ implementar ya**
**Escenario.** is_admin() tiene `grant execute ... to anon` (0002 L32). Un anónimo con la anon key puede llamar el RPC is_admin (devuelve false).

**Problema.** Superficie innecesaria: anon no necesita ejecutar is_admin (siempre da false porque auth.uid() es null). Exponerla a anon permite a un atacante sondear la existencia de la función y, si en el futuro alguien la modifica para leer algo, el grant a anon se hereda. Principio de mínimo privilegio violado.

**Solución.** `revoke execute on function public.is_admin() from anon;` dejando solo `grant execute ... to authenticated;`. Las policies que la usan están en roles `authenticated`, así que anon no la necesita. La vista artesanos_publicos no la usa.

**Idempotencia/seguridad.** n/a (DDL idempotente).

### 25. 🟡 Media · **⚡ implementar ya**
**Escenario.** El bucket 'piezas' es público de lectura (0003 L6-8) y subirImagen (productos/actions.ts L19-37) sube a `productos/<uuid>.<ext>` derivando ext del nombre de archivo del cliente sin validar contra el content-type real.

**Problema.** Fuga/abuso de Storage: el bucket público sirve cualquier objeto en él por URL adivinable-ish (uuid v4 no es enumerable, ok). Pero la extensión la pone el cliente (`file.name.split('.').pop()`), no se deriva del MIME validado; se podría subir un .svg (XSS si se sirve inline) renombrado, o un archivo cuyo content-type dice image/png pero ext .svg. El bucket público sirve con el content-type guardado, y un SVG malicioso ejecutado en el dominio del storage podría robar tokens si el dominio comparte cookies.

**Solución.** Derivar la extensión del content-type validado, no del nombre: mapear `{'image/jpeg':'jpg','image/png':'png','image/webp':'webp'}[file.type]` y rechazar si no está en el set (TIPOS ya excluye svg — bien, pero la ext aún viene del nombre). Forzar contentType al subir (ya se hace). Servir el bucket desde un subdominio sin cookies de sesión. Considerar `Content-Disposition: attachment` o `X-Content-Type-Options: nosniff` en el proxy para objetos de storage.

**Idempotencia/seguridad.** upsert:false + nombre UUID aleatorio evita colisión y sobrescritura; un reintento genera otro UUID (no pisa el anterior, pero puede dejar huérfanos — aceptable en MVP).

### 26. 🟡 Media
**Escenario.** subirImagen se ejecuta ANTES del insert/update de la fila en crearProducto/actualizarProducto. Si el insert falla (slug duplicado, error de red), la imagen ya quedó subida al bucket.

**Problema.** Objetos huérfanos en Storage y posible inconsistencia: en crearProducto, si `insert` devuelve 'duplicate' la imagen ya está en 'piezas' sin fila que la referencie (basura que crece). En actualizarProducto, si el update falla tras subir, queda una imagen huérfana y la fila conserva la URL vieja. Un atacante admin-comprometido podría además inflar storage subiendo y forzando fallos.

**Solución.** Subir la imagen DESPUÉS de validar unicidad, o limpiar en el catch: si el insert/update falla, `await supabase.storage.from('piezas').remove([path])`. Mejor: insertar la fila primero (sin imagen), luego subir y hacer update de imagen; si la subida falla, la fila existe sin imagen (estado válido). Alternativamente un job de barrido que borre objetos de 'piezas' no referenciados por productos.imagen.

**Idempotencia/seguridad.** El nombre UUID hace cada subida única; un reintento del usuario crea otra imagen. Para idempotencia real, derivar el path de un hash del contenido (mismo archivo → mismo path → upsert) evita duplicados en reintentos.

### 27. 🟡 Media · **⚡ implementar ya**
**Escenario.** metrics.ts y la página del dashboard leen artesanos completos (artesanos.ts COLS incluye rfc, regimen_fiscal, clabe) para computar alertas (sinRfc, sinClabe) y retención. El dashboard renderiza componentes cliente (charts.tsx).

**Problema.** Fuga potencial de rfc/clabe al bundle cliente: si algún dato derivado de ArtesanoAdmin (que contiene rfc/clabe) se pasa como prop a un Client Component, los campos sensibles cruzan al navegador en el payload RSC serializado. computeMetrics deriva tasaRetencion(a.rfc) en servidor (bien), pero si en algún punto se pasa el arreglo artesanos crudo a un componente cliente, rfc/clabe viajan al cliente del admin (y quedan en memoria/devtools).

**Solución.** Nunca pasar objetos ArtesanoAdmin con rfc/regimen_fiscal/clabe a Client Components. Crear un tipo de proyección (ej. ArtesanoSeguro sin campos fiscales) y pasar solo ese, o solo los agregados ya calculados (números). En listarArtesanosOpciones ya se hace bien (solo id,nombre). Auditar que metrics y charts reciban solo el objeto Metrics (números), no los arreglos crudos. Para vistas de detalle que SÍ muestran rfc/clabe al admin, mantenerlos en Server Component (no interactivo).

**Idempotencia/seguridad.** n/a (lectura).

### 28. 🟡 Media · **⚡ implementar ya**
**Escenario.** artesanoSchema (schemas.ts L16-37) acepta y persiste rfc, regimen_fiscal, clabe desde formData en crear/actualizarArtesano. La whitelist toRow los incluye. No hay control de QUIÉN entre los admins puede ver/editar datos fiscales.

**Problema.** Todos los admins ven y editan rfc/clabe de todos los artesanos (no hay segmentación). La RLS solo distingue admin/no-admin, no 'admin que maneja fiscal' vs 'admin de catálogo'. Un admin de catálogo comprometido extrae todas las CLABEs (datos bancarios) y RFCs. Además, actualizarArtesano siempre reescribe clabe/rfc; si el form omite el campo, zod lo vuelve undefined → n() lo pone NULL, BORRANDO la CLABE existente por accidente (mass-update destructivo silencioso).

**Solución.** Corto plazo: en actualizarArtesano, NO incluir rfc/clabe/regimen en el update salvo que vengan presentes en el form (partial update): construir el row solo con las claves presentes en formData, evitando que un form sin esos campos los borre a NULL. Mediano plazo: separar fiscal por columna a nivel de policy no es posible (RLS es por fila); usar una tabla aparte `artesanos_fiscal(artesano_id, rfc, clabe, regimen)` con su propia RLS exigiendo rol 'fiscal' en admins, y la vista/listado de catálogo nunca la toca.

**Idempotencia/seguridad.** El UPDATE es idempotente, pero el bug de borrado-a-NULL hace que un reintento con form parcial sea destructivo. El partial update lo corrige.

### 29. 🟡 Media
**Escenario.** requireAdmin() (auth.ts) usa supabase.rpc('is_admin') sobre el cliente con cookies y se memoiza con React cache() por request. Las páginas admin y todas las actions dependen de esta única verificación.

**Problema.** Si is_admin() o la red a GoTrue falla transitoriamente, getUser() podría devolver user pero rpc('is_admin') devolver error → el código hace `if (error || !esAdmin) redirect('/admin/login')` (bien, falla cerrado). PERO: la lectura listarProductos/listarArtesanos confía en RLS para filtrar; si por un bug futuro alguien usara el cliente anon en una action admin, RLS aún protege. El riesgo real: cache() memoiza por request, no por usuario — correcto en Next porque cada request es un usuario; sin embargo no hay verificación de que el JWT no esté revocado mid-request (token válido por firma pero admin eliminado de la tabla admins hace 1s seguiría pasando getUser, y is_admin lo cortaría — bien).

**Solución.** El diseño es correcto (falla cerrado, usa getUser que valida por red, is_admin se reconsulta). Endurecer: registrar (audit) cada redirect por error vs por no-admin para detectar ataques. Asegurar que NINGUNA action use el cliente anon de lib/supabase/server.ts (catalog) por error — esos clientes no llevan la cookie y RLS los trata como anon. Mantener la regla: en /admin SIEMPRE el cliente de requireAdmin().

**Idempotencia/seguridad.** cache() garantiza una sola verificación por request (no repite la llamada de red), consistente ante el render concurrente de varias páginas/segmentos.

### 30. 🟢 Baja
**Escenario.** productoBaseSchema valida precio_pesos como entero positivo max 10,000,000 y el servidor calcula precio_centavos = precio_pesos*100 (anti mass-assignment correcto). No se acepta precio_centavos del cliente.

**Problema.** Riesgo residual de mass-assignment: Object.fromEntries(formData) más safeParse descarta campos no declarados en el schema (zod por defecto hace strip de extras), así que un campo inyectado como `commission_rate` o `precio_centavos` o `status='publicado'` forzado se ignora salvo los whitelisted. PERO toRow para producto NO incluye `id` en update (bien) y status SÍ es editable por el admin (esperado). El único hueco: si zod estuviera en modo passthrough se colarían extras — hay que garantizar strip.

**Solución.** Confirmar que los schemas NO usan .passthrough() (no lo usan — por defecto z.object hace strip). Para defensa explícita, usar .strict() en artesanoSchema y productoBaseSchema para RECHAZAR (no solo ignorar) campos desconocidos, lo que ayuda a detectar intentos de inyección en logs: `z.object({...}).strict()`. Mantener toRow como única fuente de columnas escribibles (ya correcto).

### 31. 🟡 Media
**Escenario.** productos.artesano_id es FK ON DELETE SET NULL (0001 L26). eliminarArtesano (artesanos/actions.ts L68-77) borra el artesano; las piezas quedan con artesano_id=NULL pero conservan el campo denormalizado `maker` (nombre del taller) ya publicado.

**Problema.** Inconsistencia y posible fuga indirecta: al borrar un artesano, sus piezas publicadas siguen visibles al público mostrando `maker` (nombre del taller) pero sin vínculo. Si el motivo del borrado fue dar de baja por solicitud del artesano (derecho al olvido / baja fiscal), su nombre comercial sigue expuesto en el storefront. Además metrics.ts agrupa por artesano_id NULL como 'Sin asignar', distorsionando reportes de retención (tasaRetencion sobre rfc null = 36% aplicado a ventas sin artesano).

**Solución.** Decidir política de baja explícita: en vez de DELETE, preferir status='pausado' (soft-delete) que la vista artesanos_publicos ya excluye (where status='activo'), conservando integridad referencial y reportes. Si se borra de verdad, en la misma transacción despublicar sus piezas: `update productos set status='borrador' where artesano_id = :id` ANTES del delete, para que no queden piezas huérfanas publicadas. Hacerlo en un RPC transaccional, no en dos llamadas REST separadas.

**Idempotencia/seguridad.** Envolver en un RPC SECURITY DEFINER con check is_admin() para que despublicar+borrar sea atómico; reintentar el RPC es seguro (delete idempotente, update idempotente). Dos llamadas REST separadas NO son atómicas (si falla la 2a, queda estado parcial).

### 32. 🟢 Baja
**Escenario.** El proxy.ts hace un gate OPTIMISTA: redirige a login si !user para rutas /admin (excepto /admin/login). El matcher cubre /admin/:path*. La autoridad real es requireAdmin() en cada page/action.

**Problema.** Doble fuente de verdad de rutas: si se agrega una ruta admin que NO empiece por /admin (improbable) o un Route Handler API bajo otra ruta que toque datos admin, el proxy no lo cubre. Además el gate del proxy solo checa `user` (autenticado), NO is_admin — un usuario autenticado NO-admin pasa el proxy y solo es cortado por requireAdmin en la page. Correcto (defensa en capas) pero significa que el proxy no debe considerarse autorización, solo UX redirect.

**Solución.** Mantener requireAdmin() como única autoridad (ya está bien). No mover lógica de autz al proxy (corre en edge/proxy y getUser ahí es para UX). Documentar que toda nueva ruta que lea datos sensibles DEBE llamar requireAdmin y vivir bajo /admin. Opcional: en el proxy, además de !user, redirigir temprano si la ruta es /admin y el usuario claramente no-admin para ahorrar render, pero sin confiar en ello.

### 33. 🟢 Baja
**Escenario.** Mensajes de error de las actions reflejan error.message de Postgres/PostgREST al usuario: crearProducto devuelve `No se pudo crear: ${error.message}`, igual en artesanos y en subirImagen.

**Problema.** Fuga de información interna: error.message de PostgREST puede revelar nombres de columnas, constraints, detalles de RLS ('new row violates row-level security policy'), o estructura de la BD a un admin comprometido o en logs no protegidos. Menor (el actor ya es admin), pero ayuda a un atacante con sesión robada a mapear el esquema y planear ataques (ej. saber qué constraint UNIQUE existe).

**Solución.** Mapear errores a mensajes genéricos para el usuario y loggear el detalle solo del lado servidor: mantener el caso 'duplicate' → mensaje amigable (ya está), y para el resto devolver 'No se pudo guardar, intenta de nuevo' al cliente mientras se hace console.error/logger del error.message real en el servidor. No reflejar error.message crudo en la UI.


## Backend / Server Actions

### 34. 🔴 Alta · **⚡ implementar ya**
**Escenario.** crearProducto sube la imagen con subirImagen() (upload a bucket 'piezas' con UUID nuevo), pero el insert posterior a public.productos falla: id duplicado ('Ya existe una pieza con ese identificador'), violación de CHECK/FK, o caída de red entre el upload y el insert.

**Problema.** Fallo parcial: el archivo queda HUÉRFANO en Storage (la URL pública existe pero no hay fila que lo referencie). En cada reintento del admin se sube OTRO archivo; el bucket acumula basura no referenciable. No hay rollback porque Storage y Postgres son dos sistemas y no comparten transacción.

**Solución.** Reordenar: validar zod e INTENTAR el insert de productos PRIMERO con imagen=null (o subir y, si el insert falla, compensar). Patrón actual recomendado: subir imagen → insert; en el catch del insert, ejecutar await supabase.storage.from('piezas').remove([path]) para borrar el objeto recién subido. Refactorizar subirImagen para devolver {path, url} y conservar el path para el cleanup. Envolver: `try { const {path,url}=await subirImagen(...); const {error}=await insert({imagen:url,...}); if(error){ await supabase.storage.from('piezas').remove([path]); return {message:...}; } }`. El UNIQUE de id (PK text) ya evita doble fila; falta el cleanup del Storage.

**Idempotencia/seguridad.** El path usa crypto.randomUUID() así que reintentos no colisionan, pero por eso mismo cada reintento deja un huérfano nuevo. La compensación (remove del path en el catch) hace el reintento seguro: cero archivos huérfanos por intento fallido. La PK 'id' (UNIQUE) garantiza no duplicar la fila.

### 35. 🔴 Alta · **⚡ implementar ya**
**Escenario.** eliminarArtesano() y eliminarProducto() hacen `await supabase.from(...).delete().eq('id', id)` e IGNORAN el { error, count } devuelto; luego siempre redirect() a la lista. Caso real: la sesión del admin expiró (GoTrue sin SMTP, refresh falló en el proxy) o RLS deniega; el delete devuelve error o count=0.

**Problema.** El admin ve 'eliminado con éxito' (redirect) pero el registro SIGUE en la BD. Falsa confirmación de una acción destructiva. Peor: requireAdmin() pasa (cache de request) pero el token usado por PostgREST ya no autoriza el delete bajo RLS, o el id no existía. No hay feedback del fallo.

**Solución.** Capturar el resultado y propagar/mostrar: `const { error, count } = await supabase.from('artesanos').delete({ count:'exact' }).eq('id', id); if (error) return {message:`No se pudo eliminar: ${error.message}`}; if (count===0) return {message:'No se encontró el registro (¿ya se eliminó o no tienes permiso?)'};`. Esto exige cambiar la firma de eliminarX de Promise<void> a Promise<ActionState> y usar useActionState en DeleteButton (o un toast). Pedir `{count:'exact'}` para detectar el caso RLS/no-existe.

**Idempotencia/seguridad.** Borrar un id ya borrado es naturalmente idempotente (segundo delete da count=0); con el chequeo de count se reporta correctamente sin tratar el reintento como error fatal — distinguir count===0 'no encontrado' de error real. Seguro ante doble submit.

### 36. 🔴 Alta
**Escenario.** Dos admins (A y B) abren la ficha del MISMO artesano (o producto). A pausa al artesano y cambia su CLABE; B, sin recargar, edita la semblanza y guarda 30s después. Ambos llaman actualizarArtesano con UPDATE ... eq('id', id).

**Problema.** Condición de carrera last-write-wins: el UPDATE de B reescribe TODA la fila (toRow incluye todos los campos del form de B, con la CLABE y status VIEJOS que B tenía en pantalla). El cambio fiscal de A se pierde silenciosamente. Riesgo fiscal: una CLABE corregida vuelve a la incorrecta sin que nadie lo note.

**Solución.** Bloqueo optimista por versión. Añadir columna `version int not null default 0` (o usar updated_at, que ya existe en productos vía trigger). Enviar el valor leído como hidden field y condicionar el UPDATE: `.update({...row, version: v+1}).eq('id', id).eq('version', vCliente)` con `{count:'exact'}`. Si count===0 → return {message:'Otro administrador modificó este registro; recarga y vuelve a aplicar tus cambios.'}. Para productos: `.eq('updated_at', updatedAtCliente)` (pero ojo: el trigger touch_updated_at cambia updated_at en cada UPDATE, así que comparar el valor previo funciona). Para artesanos hay que AÑADIR version/updated_at (la tabla no la tiene).

**Idempotencia/seguridad.** El guard `.eq('version', vCliente)` hace el UPDATE condicional: reintentar el mismo submit dos veces solo aplica una vez (la segunda ve version ya incrementada → count=0). Concurrencia resuelta a nivel BD, no de app.

### 37. 🟡 Media · **⚡ implementar ya**
**Escenario.** El admin hace doble clic en 'Guardar' al crear un artesano (o la red tarda y reintenta). El botón tiene disabled={pending}, pero el primer request ya viajó; un segundo submit por Enter+clic, o un reintento del navegador tras timeout, dispara crearArtesano dos veces con el MISMO slug.

**Problema.** Doble submit. El primer insert crea la fila; el segundo choca con `slug text unique`. La app ya mapea 'duplicate' a 'Ya existe un artesano con ese slug.' — pero eso muestra un ERROR al admin aunque la creación SÍ funcionó (la primera vez), generando confusión ('¿se creó o no?'). Para productos pasa igual con la PK id.

**Solución.** El UNIQUE(slug) / PK(id) ya garantiza no duplicar (correcto). Mejorar UX: ante error 'duplicate', en lugar de mostrar error, tratar como éxito idempotente: re-leer por slug/id y si existe → revalidatePath + redirect a la lista (o a la ficha). Alternativa más limpia: usar `.insert(...).select().single()` y, si el error es 23505 (unique_violation, detectar por error.code==='23505' en vez de includes('duplicate') que es frágil ante i18n del mensaje), hacer redirect normal. Mantener disabled={pending} para el caso común.

**Idempotencia/seguridad.** El constraint UNIQUE en BD (slug para artesanos, PK id para productos) es el respaldo real: dos submits → una fila. Tratar 23505 como redirect-éxito convierte el doble submit en operación idempotente desde la perspectiva del usuario. Detectar por error.code, no por substring del mensaje.

### 38. 🟡 Media · **⚡ implementar ya**
**Escenario.** El admin escribe el precio como '1500.50' (con punto decimal y centavos) o '1,500' (separador de miles es-MX) en el campo precio_pesos. zod: z.coerce.number().int(). '1500.50' → 1500.5 → .int() FALLA ('Sin centavos'); '1,500' → coerce(Number('1,500'))=NaN → falla. Pero '1500 ' con espacio, o '1.5e3' → 1500 PASA.

**Problema.** Coerción de tipos inconsistente. Number('1.5e3')===1500 pasa todos los checks (.int().positive().max), dando un precio que el admin NO escribió conscientemente. Number(' 1500 ')===1500 también pasa por trim implícito de Number. El servidor es autoridad de precio y multiplica *100 → precio_centavos sin que coincida con la intención. Casos como '0x10', 'Infinity' los corta .int()/.max, pero la notación científica entra.

**Solución.** No usar z.coerce.number() para dinero. Validar como string primero y parsear estricto: `precio_pesos: z.string().trim().regex(/^\d{1,8}$/, 'Solo pesos enteros, sin puntos ni comas').transform(Number)`. Esto rechaza '1.5e3', '1500.50', '1,500', ' 1500 ' con espacios internos, y deja solo dígitos. Mantener el *100 en toRow. Para la UI, el input type=number ayuda pero NO valida en el servidor (un POST directo manda lo que sea).

**Idempotencia/seguridad.** n/a (validación pura, sin estado). Pero refuerza la regla 'servidor es autoridad de precio': el cliente nunca decide centavos.

### 39. 🔴 Alta · **⚡ implementar ya**
**Escenario.** Un atacante (o un admin con DevTools) hace un POST directo a la Server Action de actualizarProducto incluyendo en el FormData campos NO esperados: precio_centavos=1, moneda='USD', updated_at='2099-01-01', created_at, o id de otro producto. Las Server Actions son endpoints POST alcanzables sin pasar por el form.

**Problema.** Mass assignment. Aunque toRow() es whitelist (bien), el riesgo concreto es: (a) precio_centavos NO está en zod ni en toRow → ignorado, correcto; (b) PERO Object.fromEntries(formData) + zod con .strip() por defecto NO falla ante campos extra, solo los descarta — está OK para los campos cubiertos. El riesgo REAL: el campo `id` del UPDATE viene de formData.get('id') SIN validar contra el slug regex, permitiendo `.eq('id', cualquierCosa)` — un admin puede editar CUALQUIER producto cambiando el hidden id (IDOR entre productos, mitigado porque is_admin ve todo, pero rompe el modelo si hubiera multi-tenant futuro).

**Solución.** 1) Validar el id del UPDATE con el mismo slug schema antes del .eq: `const idParsed = slug.safeParse(formData.get('id')); if(!idParsed.success) return {message:'Identificador inválido'}`. 2) Confirmar que zod usa .strip (default) y NUNCA .passthrough(). 3) Para artesanos, validar que el id sea uuid antes del .eq('id', id) (hoy se pasa crudo). 4) Documentar que toRow es la única superficie de escritura. RLS protege a nivel fila pero NO a nivel columna, por eso la whitelist de toRow es obligatoria (ya está bien).

**Idempotencia/seguridad.** n/a (es authz/validación). La defensa es whitelist + validación de id; no depende de reintentos.

### 40. 🟡 Media
**Escenario.** Error de red a mitad de actualizarProducto JUSTO después del UPDATE exitoso en Postgres pero ANTES de que la respuesta (el redirect NEXT_REDIRECT) llegue al navegador. El admin no ve confirmación, asume que falló, y reenvía el formulario.

**Problema.** El UPDATE ya se aplicó; el reenvío lo aplica OTRA VEZ. Para un UPDATE de campos idempotente (mismos valores) no hay daño de datos, PERO si el reenvío trae una imagen nueva, subirImagen corre de nuevo → segundo archivo en Storage + el primero queda huérfano (la fila ahora apunta al segundo). Acumulación de huérfanos por reintento.

**Solución.** Mismo cleanup de Storage del caso 1 (borrar el path subido si algo falla, y borrar la imagen ANTERIOR al reemplazarla en update: leer row.imagen actual y remove() del path viejo tras update OK). Para el UPDATE en sí, es idempotente por naturaleza (mismos valores → mismo resultado). Considerar mostrar al admin un estado 'guardado' optimista en cliente y deshabilitar reenvío. No requiere idempotency-key porque no crea filas nuevas.

**Idempotencia/seguridad.** Un UPDATE con los mismos valores es idempotente por diseño (no como un INSERT). El riesgo no es la fila sino los archivos de Storage: resolver borrando el path anterior al sustituir imagen y el nuevo si el update falla.

### 41. 🔴 Alta · **⚡ implementar ya**
**Escenario.** El admin asigna un producto a un artesano vía el SelectField artesano_id (un uuid válido). Entre que se cargaron las opciones y el submit, OTRO admin eliminó ese artesano. O bien, vía POST directo, se manda un artesano_id uuid bien formado pero INEXISTENTE.

**Problema.** zod solo valida el FORMATO uuid (regex), no la existencia. El insert/update llega a Postgres. La FK productos.artesano_id REFERENCES artesanos(id) ON DELETE SET NULL rechaza el insert con violación de FK (error 23503) si el uuid no existe → el admin ve un mensaje crudo `No se pudo crear: insert or update violates foreign key constraint`. Confuso. Si el artesano se borró DESPUÉS, la fila ya existía con artesano_id que luego pasó a NULL (SET NULL), comportamiento esperado.

**Solución.** La FK ya protege la integridad (correcto, no se crea un producto colgando de un artesano fantasma). Mejorar el mapeo de error: detectar error.code==='23503' y devolver {message:'El artesano seleccionado ya no existe; recarga la lista.'} en vez del mensaje crudo de Postgres. Opcional: re-validar existencia con un select previo, pero la FK es la autoridad y evita la race (check-then-insert tendría TOCTOU; la FK no).

**Idempotencia/seguridad.** La FK se evalúa en la transacción del insert, sin ventana TOCTOU: si el artesano desaparece justo antes, el insert falla atómicamente. Reintentar es seguro (o falla igual, o el admin elige otro artesano). No requiere lógica extra de idempotencia.

### 42. 🟡 Media · **⚡ implementar ya**
**Escenario.** Un error NO controlado escapa dentro de un Server Action: por ejemplo subirImagen lanza por un fallo de red del Storage que NO es el catch previsto, o supabase.rpc('is_admin') en requireAdmin lanza (no error tipado, sino throw real por timeout del fetch a GoTrue self-hosted vía Tailscale).

**Problema.** En crear/actualizar, requireAdmin() corre ANTES del try/catch de imagen; si lanza por timeout de red (Tailscale caído), la excepción burbujea como 500 genérico de Next, sin mensaje útil y sin distinguir 'red caída' de 'no autorizado'. El admin ve una pantalla de error rota. Además, un throw entre el upload y el insert (caso 1) ya no se limpia.

**Solución.** Envolver las llamadas de red de requireAdmin en manejo explícito: si getUser()/rpc lanzan (no solo devuelven error), capturar y redirect('/admin/login?e=red') o devolver ActionState con mensaje. En las actions mutantes, NO dejar que un throw inesperado caiga al boundary: envolver el cuerpo (excepto redirect, que DEBE re-lanzarse: `if (isRedirectError(e)) throw e`) en try/catch que devuelva {message:'Error temporal, reintenta.'}. Crítico: redirect() y NEXT_REDIRECT no deben tragarse — re-lanzar usando isRedirectError de next/navigation.

**Idempotencia/seguridad.** n/a directamente, pero el manejo correcto evita estados a medias (ej. dejar el upload hecho y reportar falso fallo). Si se agrega try/catch global, asegurar que el redirect siga propagando.

### 43. 🟡 Media
**Escenario.** crearProducto / actualizarProducto hacen revalidatePath('/tienda') y revalidatePath(`/tienda/${id}`). Pero un producto en status 'borrador' o 'agotado' NO se sirve al público (RLS productos_publicados_select exige status='publicado'). El admin crea un borrador y revalida /tienda igual.

**Problema.** Revalidación de cache imprecisa: se purga el cache público de /tienda y /tienda/[id] aunque el producto sea borrador (no visible). Inverso más grave: si un producto pasa de 'publicado' a 'borrador'/'agotado', se revalida /tienda/[id] — bien — pero la página /tienda/[id] cacheada de un producto recién despublicado podría quedar servida si el path no coincide exactamente (id vs slug). También: al cambiar artesano_id, el maker denormalizado en otras vistas no se revalida.

**Solución.** Revalidar /tienda solo cuando el status final o inicial sea 'publicado' (un cambio entre dos estados no-públicos no afecta la tienda): `if (statusNuevo==='publicado' || statusPrevio==='publicado') { revalidatePath('/tienda'); revalidatePath(`/tienda/${id}`); }`. Para crear, revalidar /tienda solo si status==='publicado'. Verificar que la ruta pública sea realmente /tienda/[id] con el mismo id (productos.id ES el slug de URL, confirmado en 0001) — coincide, OK. Confirmar contra los docs de Next 16 (este Next NO es el estándar) que revalidatePath con segmento dinámico purga la entrada correcta.

**Idempotencia/seguridad.** Revalidar de más es seguro (idempotente: vuelve a generar la página). El riesgo es de rendimiento/correctitud de cache, no de datos. Revalidar de MENOS (olvidar un path) deja stale. Preferir revalidar de más antes que de menos, pero acotar al status publicado.

### 44. 🔴 Alta
**Escenario.** Admin A pausa/elimina al admin que está logueado, o un admin elimina su PROPIA fila de public.admins (la policy admins_admin_write permite a cualquier admin escribir admins, incluido borrarse). O dos admins en paralelo: A elimina a B mientras B ejecuta una action.

**Problema.** requireAdmin() está memoizada con React cache() POR REQUEST: dentro de UN request, is_admin() se evalúa una vez. Pero si B perdió el rol entre páginas, su próximo request lo detecta y redirige — correcto. El riesgo: un admin puede borrarse a sí mismo de admins (no hay guard que impida quedar con CERO admins), dejando el panel sin acceso (el primer admin se sembró por psql; recuperar exige psql de nuevo). También: borrar al último admin rompe is_admin() para todos.

**Solución.** Añadir guard en BD: trigger BEFORE DELETE/UPDATE en public.admins que impida borrar la última fila: `if (select count(*) from public.admins) <= 1 then raise exception 'No puedes eliminar al último administrador'`. Y/o policy/check que impida que un admin se borre a sí mismo salvo que exista otro. Esto NO es una action del panel hoy (admins se gestiona por psql), pero si se expone, es obligatorio. Mientras tanto, documentar que admins solo se toca por psql.

**Idempotencia/seguridad.** n/a; es una invariante de negocio (>=1 admin) garantizada por trigger/constraint en BD, no por la app. El trigger lo hace seguro ante concurrencia (dos deletes simultáneos: la transacción que dejaría 0 admins aborta).

### 45. 🟡 Media · **⚡ implementar ya**
**Escenario.** subirImagen valida file.type contra ['image/jpeg','image/png','image/webp'] y file.size, pero el path se construye con `file.name.split('.').pop()` para la extensión. Un atacante-admin sube un archivo llamado `pieza.html` o `foto.svg` con Content-Type image/png falsificado, o sin extensión (ext='jpg' por fallback).

**Problema.** El nombre del archivo es controlado por el cliente y NO se valida la extensión. Un .svg con script o un .html servido desde el bucket PÚBLICO 'piezas' (lectura anon) podría ejecutarse como XSS si el navegador lo interpreta por Content-Type. file.type se confía pero es manipulable. La extensión derivada del nombre puede no coincidir con el contentType real, sirviendo contenido inesperado.

**Solución.** Derivar la extensión del file.type validado (no del nombre): `const ext = {'image/jpeg':'jpg','image/png':'png','image/webp':'webp'}[file.type]`. Ya se valida file.type contra TIPOS; usar ese mapeo elimina la dependencia del nombre. Forzar contentType en el upload (ya se hace). Idealmente verificar magic bytes (leer los primeros bytes y comprobar la firma JPEG/PNG/WebP) porque file.type viene del cliente. Configurar el bucket para servir con Content-Disposition o un content-type seguro. Sanitizar/ignorar file.name por completo.

**Idempotencia/seguridad.** n/a (validación de entrada). El UUID del path ya evita colisiones de nombre; el riesgo es de tipo de contenido, no de duplicado.

### 46. 🟡 Media
**Escenario.** El admin sube una imagen de 4.9 MB por la red lenta de Tailscale (HTTP, self-hosted). El upload tarda >la duración máxima de la Server Action / del proxy. O el body del POST excede el límite de body de Next 16 Server Actions (configurable, por defecto ~1MB para algunas configs).

**Problema.** Timeout o límite de body: la Server Action recibe un body multipart con la imagen; si el límite de bodySizeLimit de Server Actions de Next no se subió, un archivo de varios MB se RECHAZA antes de llegar al código (la validación de 5MB en subirImagen nunca corre). El admin ve un error opaco de plataforma, no el mensaje amable 'La imagen supera 5 MB'. Por Tailscale/HTTP el upload puede además exceder el timeout y dejar un upload parcial.

**Solución.** Configurar explícitamente en la config de Next 16 el bodySizeLimit de Server Actions a un valor >5MB (ej. 8mb) para que la validación propia de 5MB sea la que gobierne y dé el mensaje correcto. Verificar el nombre/ubicación exacto de la opción en los docs de ESTE Next (no asumir la API estándar: experimental.serverActions.bodySizeLimit puede haber cambiado). Considerar subir la imagen directamente a Storage desde el cliente con una signed upload URL (createSignedUploadUrl) en vez de pasar el binario por la Server Action, evitando el límite de body y el doble salto de red.

**Idempotencia/seguridad.** Subida directa a Storage con UUID es idempotente por path único; si falla, no deja fila. Mientras siga por Server Action, el cleanup del caso 1 cubre el upload parcial.

### 47. 🟡 Media · **⚡ implementar ya**
**Escenario.** actualizarArtesano borra datos fiscales sin querer: el form siempre envía rfc, regimen_fiscal y clabe. Si el admin abre la ficha y guarda tras tocar solo la semblanza, los campos fiscales vienen con su defaultValue. Pero si el navegador NO rellenó un campo (ej. autofill falló, o un POST parcial), optText convierte '' → undefined → n() → NULL.

**Problema.** Borrado accidental de datos sensibles (RFC/CLABE) por el patrón 'el form manda todos los campos y toRow reescribe toda la fila'. Un '' en clabe (campo vaciado por error o no incluido en un POST manipulado) se persiste como NULL, perdiendo un dato fiscal crítico para retenciones/dispersión. No hay distinción entre 'no enviado' y 'enviado vacío para borrar'.

**Solución.** Para campos sensibles, hacer UPDATE parcial: construir el patch solo con las claves PRESENTES en formData (formData.has('clabe')), no con un objeto completo. O añadir confirmación UX al vaciar un campo fiscal previamente lleno. Alternativa robusta: separar la edición fiscal en su propia action/formulario con su propio submit, de modo que editar la semblanza nunca toque rfc/clabe. Dado que rfc/clabe alimentan tasaRetencion (36% vs 10.5%), un borrado accidental cambia la retención fiscal — alto impacto.

**Idempotencia/seguridad.** n/a (es prevención de pérdida de datos). El UPDATE parcial reduce la superficie: solo se escriben campos explícitamente provistos; reaplicarlo es idempotente.

### 48. 🟢 Baja
**Escenario.** El slug de artesano se valida con regex /^[a-z0-9-]+$/ pero NO se normaliza ni se restringe longitud ni guiones múltiples. Un admin crea slug='---' o 'a'.repeat(5000) o un slug que choca con una ruta del sitio (ej. 'tienda', 'admin', 'carrito').

**Problema.** Slugs degenerados: '---' pasa el regex; un slug larguísimo infla la URL; un slug igual a una ruta reservada ('admin', 'tienda', 'marca', 'carrito') puede colisionar con el routing de Next o confundir. productos.id (slug) igual: 'nuevo' chocaría con /admin/productos/nuevo. Un id de producto = 'nuevo' rompería /tienda/nuevo o /admin/productos/nuevo si se reutiliza el patrón.

**Solución.** Endurecer el schema slug: `.min(2).max(60).regex(/^[a-z0-9]+(?:-[a-z0-9]+)*$/, 'minúsculas, números, guiones simples')` (rechaza guiones al inicio/fin y dobles). Añadir blocklist de slugs reservados: `.refine(v => !['admin','tienda','marca','carrito','nuevo','login','api'].includes(v), 'slug reservado')`. Aplicar el mismo refine al id de producto (productoCrearSchema) porque 'nuevo' colisiona con la ruta /admin/productos/nuevo.

**Idempotencia/seguridad.** n/a (validación). El UNIQUE(slug)/PK(id) sigue garantizando unicidad; esto solo evita valores patológicos.

### 49. 🟡 Media
**Escenario.** Object.fromEntries(formData) se usa para construir el input de zod en TODAS las actions. Si el form (o un POST manipulado) envía un campo REPETIDO (ej. dos inputs name='status'), Object.fromEntries conserva solo el ÚLTIMO. Si envía 'imagen' como campo de texto además del File, o envía status='publicado' como array.

**Problema.** Pérdida/confusión de datos por colisión de claves: Object.fromEntries colapsa duplicados al último valor, sin error. Un atacante puede enviar status='borrador' (visible en UI) y un segundo status='publicado' que gana, evadiendo la intención. Para 'imagen', si llega como texto en vez de File, el flujo `file instanceof File` lo ignora y no sube nada, pero zod no lo nota. El campo 'id' del producto en edición coexiste con 'id_display' (inofensivo) pero ilustra el patrón frágil.

**Solución.** No confiar en Object.fromEntries para campos críticos enumerados. Para el status (enum), zod ya rechaza valores fuera de la lista, pero NO la duplicación. Construir el objeto explícitamente leyendo cada campo con formData.get('campo') (toma el primero) en vez de fromEntries, o validar que no haya claves duplicadas inesperadas. Como mínimo, para enums sensibles (status) y precio, leer con .get() explícito. zod con .strip() descarta extras, lo que está bien, pero la colisión de duplicados sigue.

**Idempotencia/seguridad.** n/a (parsing). La defensa es construir el payload de forma determinista (get explícito) en lugar de depender del orden de FormData.

### 50. 🔴 Alta
**Escenario.** Concurrencia en Storage: dos actions (o dos pestañas del admin) suben imagen para el MISMO producto casi a la vez durante un actualizarProducto. Cada subirImagen genera un UUID distinto y hace upsert:false. Ambos uploads tienen éxito (paths distintos); ambos UPDATE corren; gana el último UPDATE.

**Problema.** Fallo parcial + huérfano por concurrencia: el producto queda apuntando a la imagen del UPDATE ganador; la imagen del UPDATE perdedor queda HUÉRFANA en el bucket (subida con éxito, jamás referenciada). No hay limpieza de la imagen ANTERIOR del producto al reemplazarla, así que cada cambio de imagen acumula el archivo viejo en Storage indefinidamente.

**Solución.** Al reemplazar imagen en actualizarProducto: leer primero la imagen actual del producto (select imagen where id), hacer el UPDATE con la nueva, y SOLO si el UPDATE tuvo éxito, remove() del path viejo (parseando el path desde la URL pública). Combinar con bloqueo optimista (caso 3) por updated_at para que solo un UPDATE gane y los demás reporten conflicto, evitando subir imágenes que nunca se usarán. Programar un job/escaneo periódico que liste objetos en 'piezas' sin fila en productos.imagen y los borre (recolección de huérfanos).

**Idempotencia/seguridad.** El path por UUID evita sobreescritura accidental (bien) pero no evita huérfanos. El bloqueo optimista + cleanup del path anterior hace que reintentos/concurrencia converjan a 'una imagen por producto, cero huérfanos'. El remove() es idempotente (borrar un path ya borrado no falla de forma crítica).

### 51. 🟢 Baja · **⚡ implementar ya**
**Escenario.** iniciarSesion(): tras signInWithPassword OK, llama supabase.rpc('is_admin'); si NO es admin, signOut() y devuelve mensaje. Pero si la red falla entre el signIn y el rpc (Tailscale), o el rpc devuelve error (no false), `data: esAdmin` es undefined → !esAdmin true → signOut → 'no tiene acceso'.

**Problema.** Un admin LEGÍTIMO ve 'Esta cuenta no tiene acceso de administrador' cuando en realidad fue un fallo de red del rpc (esAdmin undefined por error, no por no-admin). Mensaje engañoso y, peor, hace signOut de una sesión válida, obligando a reloguear. No se distingue error de red de 'no es admin'.

**Solución.** Capturar el error del rpc por separado: `const { data: esAdmin, error: adminErr } = await supabase.rpc('is_admin'); if (adminErr) { return {message:'No se pudo verificar el acceso (problema de red). Reintenta.'} } if (!esAdmin) { await supabase.auth.signOut(); return {message:'Esta cuenta no tiene acceso de administrador.'} }`. No hacer signOut ante error de red (la sesión es válida; el problema es la verificación). Mismo patrón ya falta en requireAdmin (caso 9).

**Idempotencia/seguridad.** n/a (login es naturalmente reintentable; signInWithPassword no crea estado duplicado). Solo mejora la robustez del manejo de error de red.


## Idempotencia / concurrencia

### 52. 🔴 Alta · **⚡ implementar ya**
**Escenario.** El admin llena el form de 'nueva pieza' (productos/nuevo), hace doble click en 'Guardar' o la red tarda y reintenta. Dos POST a la Server Action crearProducto llegan con el mismo id slug (ej. 'tal-03').

**Problema.** Ambos requests pasan zod y llegan a .insert({ id: 'tal-03', ... }). El segundo viola el PK de productos. El primer insert crea la pieza; el segundo devuelve error y la UI muestra 'Ya existe una pieza con ese identificador.' al MISMO admin que acaba de crearla con éxito (confusión: cree que falló cuando sí se creó). Además subirImagen ya corrió DOS veces -> 2 objetos en el bucket, uno huérfano.

**Solución.** El PK text de productos YA es el respaldo correcto contra duplicados (no se necesita UNIQUE extra). Arreglar dos cosas: (1) en crearProducto, ante violación de PK, en vez de mostrar error, hacer un SELECT del id y si la fila existe y coincide con lo que se intentó insertar, tratar el doble-submit como éxito y redirect('/admin/productos') (idempotencia a nivel app). (2) En el cliente, deshabilitar el submit con `pending` de useActionState (ya existe `disabled={pending}`) pero AÑADIR guardia: el form usa progressive enhancement, así que en el componente envolver con un flag useRef para ignorar el segundo submit antes de que React hidrate.

**Idempotencia/seguridad.** El PK de productos.id garantiza que un doble insert nunca crea dos filas (constraint en BD, no solo app). La capa app convierte el segundo intento en una respuesta idéntica (misma pieza) en vez de un falso error.

### 53. 🔴 Alta · **⚡ implementar ya**
**Escenario.** subirImagen() en crearProducto/actualizarProducto sube el File al bucket 'piezas' ANTES de hacer el insert/update de la fila. Si el insert falla después (PK duplicado, validación de FK artesano_id, error de red, timeout), el objeto en storage queda subido pero ninguna fila lo referencia.

**Problema.** Cada reintento de crearProducto con el mismo form genera un path nuevo `productos/<randomUUID>.<ext>` (upsert:false + UUID aleatorio), así que NO sobreescribe: acumula objetos huérfanos en el bucket público en cada fallo/reintento. Fuga de storage y archivos públicos sin dueño. Además el orden 'sube imagen, luego inserta' no es transaccional.

**Solución.** Invertir cuando sea posible: insertar/actualizar la fila PRIMERO (con imagen=null o conservando la previa) y subir la imagen después, o envolver en try/catch que borre el objeto subido si el insert falla: `if (insertError && uploadedPath) await supabase.storage.from('piezas').remove([uploadedPath])`. Refactor: subirImagen debe devolver { path, publicUrl } para poder hacer rollback del path exacto. Para reintentos, derivar el path del id de la pieza de forma determinista (`productos/${id}.<ext>`) con upsert:true, así un reintento sobreescribe en vez de acumular huérfanos.

**Idempotencia/seguridad.** Path determinista por id de pieza + upsert:true hace la subida idempotente (reintentar produce el mismo objeto, no uno nuevo). El rollback compensatorio del objeto ante fallo de insert evita huérfanos. n/a para transaccionalidad real (storage y Postgres no comparten transacción), por eso se usa compensación.

### 54. 🔴 Alta · **⚡ implementar ya**
**Escenario.** Dos admins (o el mismo admin en dos pestañas) abren la MISMA pieza 'tal-01' para editar. Admin A cambia el precio a $1200; Admin B, con la versión vieja cargada, cambia solo la descripción y guarda 30s después. Ambos llaman actualizarProducto con .update(row).eq('id','tal-01').

**Problema.** Lost update clásico last-write-wins: el update de B reescribe TODOS los campos del whitelist (incluye precio_centavos calculado desde el precio viejo que B tenía en pantalla), pisando el $1200 de A. El precio vuelve a su valor anterior sin que nadie lo note. El trigger touch_updated_at no protege, solo registra.

**Solución.** Optimistic locking con updated_at: el form lleva un hidden `updated_at` (el valor leído al cargar). En actualizarProducto, condicionar el update: `.update(row).eq('id', id).eq('updated_at', updatedAtDelForm)` y revisar el count de filas afectadas (supabase: `.select()` tras update o `{ count: 'exact' }`). Si 0 filas afectadas -> alguien más editó; devolver { message: 'Esta pieza fue modificada por otra sesión. Recarga y vuelve a aplicar tus cambios.' } sin pisar nada.

**Idempotencia/seguridad.** El predicado eq('updated_at', X) hace el update idempotente y seguro ante concurrencia: solo aplica si el estado base no cambió. Un reintento del MISMO request (mismo updated_at base) que ya tuvo éxito afectará 0 filas la segunda vez (porque updated_at ya cambió), y se debe distinguir 'reintento de mi propio éxito' de 'conflicto real' comparando el contenido.

### 55. 🟡 Media · **⚡ implementar ya**
**Escenario.** La detección de duplicados en crearArtesano/crearProducto hace `error.message.includes('duplicate')`. Supabase/Postgres puede devolver el mensaje localizado o con texto distinto ('duplicate key value violates unique constraint "productos_pkey"'), o el código SQLSTATE 23505 sin la palabra 'duplicate' según versión/locale.

**Problema.** Si el texto no contiene 'duplicate' (locale es_MX, cambio de versión de Postgres self-hosted, o constraint distinto como slug UNIQUE de artesanos), el mensaje al admin cae al genérico 'No se pudo crear: ...' filtrando el nombre interno del constraint. Peor: lógica de idempotencia que dependa de este string-match se rompe en silencio.

**Solución.** No hacer match por substring del mensaje. Usar el code de PostgrestError: `if (error.code === '23505')` (unique_violation). Distinguir además QUÉ constraint con error.details/constraint para mensaje preciso ('slug ya usado' vs 'id de pieza ya usado'). Centralizar en un helper `esViolacionUnica(error)` reutilizable por artesanos y productos.

**Idempotencia/seguridad.** n/a (es robustez de detección, habilita el resto de lógica idempotente que depende de reconocer fiablemente la colisión de clave única).

### 56. 🔴 Alta · **⚡ implementar ya**
**Escenario.** eliminarProducto / eliminarArtesano hacen `.delete().eq('id', id)` y siempre redirect, sin mirar cuántas filas se borraron. El admin hace doble click en 'Eliminar' (DeleteButton tras window.confirm), o reintenta tras un timeout.

**Problema.** El segundo delete no encuentra la fila (ya borrada) y es un no-op silencioso: la UI no distingue 'borré algo' de 'no había nada que borrar' de 'RLS me lo negó y devolvió 0 filas'. Sin feedback, el admin no sabe si su acción tuvo efecto. En artesanos, además, el ON DELETE SET NULL ya desasoció productos en el primer borrado; un reintento no revierte nada pero tampoco avisa.

**Solución.** Pedir el conteo: `const { error, count } = await supabase.from('productos').delete({ count: 'exact' }).eq('id', id)`. Si error -> { message }. Si count === 0 -> ya estaba borrado (idempotente): mostrar mensaje informativo neutro ('La pieza ya no existe.') en vez de fingir éxito ciego. Cambiar la firma de eliminar* para devolver ActionState en vez de void, así la UI puede reaccionar.

**Idempotencia/seguridad.** DELETE es naturalmente idempotente (borrar dos veces deja el mismo estado final: ausente). El count permite distinguir el reintento (count 0) del borrado efectivo (count 1) sin tratar el reintento como error. Seguro ante doble click.

### 57. 🔴 Alta · **⚡ implementar ya**
**Escenario.** Admin A crea artesano con slug 'taller-ana'; en paralelo, otra pestaña/admin crea otro con el mismo slug 'taller-ana'. artesanos.slug es UNIQUE.

**Problema.** El primer insert gana; el segundo viola la constraint UNIQUE(slug). Hoy se mapea bien a 'Ya existe un artesano con ese slug.' PERO el form NO reenvía el id en creación, así que el admin que pierde la carrera no tiene forma de recuperar lo escrito salvo cambiar el slug; y como crearArtesano no sube imagen, no hay huérfanos, pero sí pérdida de UX. Si en el futuro se añade subida de foto a crearArtesano, replicaría el problema de objetos huérfanos.

**Solución.** Mantener UNIQUE(slug) como respaldo (correcto). Mejorar UX: ante 23505 con constraint del slug, devolver el error mapeado al campo `errors: { slug: ['Ese slug ya está en uso'] }` (no solo message global) para que el form lo marque inline y conserve el resto de campos vía defaultValue/estado. Considerar generar slug sugerido con sufijo (taller-ana-2) en el cliente al detectar colisión.

**Idempotencia/seguridad.** UNIQUE(slug) en BD garantiza unicidad ante inserts concurrentes (la BD serializa, no la app). El doble-submit del MISMO admin con el mismo slug es seguro: o crea una vez, o colisiona consigo mismo y se le informa sin crear duplicado.

### 58. 🟡 Media
**Escenario.** Admin edita una pieza y solo sube una imagen nueva (sin tocar otros campos), o cambia status de 'borrador' a 'publicado'. actualizarProducto reconstruye TODA la fila con toRow() y la pisa entera, recalculando precio_centavos desde precio_pesos del form.

**Problema.** Como toRow siempre incluye TODOS los campos, un update 'parcial' en intención es un overwrite total en realidad. Si entre el load del form y el submit el precio fue cambiado por otra acción (otro admin, o un proceso futuro de inventario que marque 'agotado'), ese cambio se pierde. Es la misma raíz del lost update pero por campos no editados en esta sesión.

**Solución.** Combinar con el optimistic locking del caso de updated_at (resuelve la raíz). Adicionalmente, para campos que el form no pretende cambiar, no enviarlos: pero como el modelo es overwrite-completo, lo correcto aquí es el guard de updated_at + recargar y reaplicar ante conflicto. Si se quiere granularidad, separar acciones (cambiarStatusProducto, cambiarPrecioProducto) que hagan updates de columnas específicas en vez de la fila entera.

**Idempotencia/seguridad.** Reaplicar el mismo update completo es idempotente por sí mismo (mismo resultado), pero NO es seguro ante concurrencia sin el predicado updated_at. La separación por acción reduce la superficie de colisión.

### 59. 🔴 Alta
**Escenario.** FUTURO (módulo inventario/órdenes diferido): se añade columna stock a productos y el checkout decrementa stock al pagar. Dos compradores pagan la última unidad casi al mismo tiempo; o un webhook de Stripe se reentrega y se procesa dos veces.

**Problema.** Si el decremento se hace leyendo stock en la app y escribiendo (read-modify-write), dos requests concurrentes leen stock=1, ambos calculan 0 y ambos venden -> sobreventa. Un webhook reprocesado decrementaría dos veces la misma orden.

**Solución.** Decremento atómico condicional en una sola sentencia dentro de la transacción de la orden: `UPDATE productos SET stock = stock - :q WHERE id = :id AND stock >= :q` y verificar rows-affected: 0 => sin stock, abortar/no cobrar. Para el webhook: tabla processed_webhook_events con UNIQUE(event_id), insertar-o-saltar dentro de la txn; procesar el decremento solo si el insert del event_id fue nuevo. Idempotency-Key en el PaymentIntent.

**Idempotencia/seguridad.** El UPDATE ... WHERE stock >= q es atómico (Postgres bloquea la fila), imposibilita sobreventa sin lock de app. UNIQUE(event_id) hace el reprocesamiento de webhook un no-op. CHECK(stock >= 0) como red de seguridad final en BD.

### 60. 🟡 Media
**Escenario.** El admin borra un artesano (eliminarArtesano) que tiene piezas asignadas. FK productos.artesano_id es ON DELETE SET NULL.

**Problema.** Las piezas quedan con artesano_id = NULL silenciosamente. En el dashboard (metrics.ts) esas piezas caen al cubo 'Sin asignar' en topArtesanos y la retención fiscal se calcula con tasaRetencion(null) = 36% (la tasa SIN RFC), distorsionando comisión/retención/neto simulados. El admin no recibe advertencia de que está orfanando piezas y alterando los cálculos fiscales.

**Solución.** Antes de borrar, contar piezas dependientes: `select count(*) from productos where artesano_id = :id`. Si > 0, en eliminarArtesano devolver confirmación explícita ('Este artesano tiene N piezas; al borrarlo quedarán sin asignar y su cálculo fiscal cambiará. ¿Continuar?') en vez de borrar en silencio. Alternativa de diseño: en vez de DELETE, soft-delete (status='pausado' ya existe) para no perder la relación fiscal. Considerar status='archivado'.

**Idempotencia/seguridad.** El DELETE sigue siendo idempotente; el riesgo es de consistencia/efectos colaterales, no de duplicación. El conteo previo no es atómico respecto al delete (una pieza podría asignarse entre el count y el delete), pero el impacto es informativo, aceptable.

### 61. 🔴 Alta
**Escenario.** FUTURO (al activar el módulo de órdenes y dispersión): se necesitará emitir un payout por (orden, artesano) tras order.paid, y los efectos cruzados entre módulos (payout + CFDI) se disparan por evento.

**Problema.** Si el efecto se dispara en el mismo request del webhook y este se reentrega o el job se reintenta, se podría pagar dos veces al artesano o emitir dos CFDI por la misma venta. Sin un registro durable, un crash entre 'orden marcada pagada' y 'payout creado' pierde el efecto.

**Solución.** Patrón outbox: en la MISMA transacción que marca la orden pagada, insertar una fila en outbox_events (UNIQUE por (order_id, tipo)). Un worker lee outbox pendientes y ejecuta payout/CFDI con idempotency key por (order, seller); el registro de payout tiene UNIQUE(order_id, seller_id) y se usa Idempotency-Key de Stripe en el Transfer. Marcar el outbox como procesado solo tras éxito.

**Idempotencia/seguridad.** UNIQUE(order_id, seller_id) en payouts y UNIQUE(order_id, tipo) en outbox garantizan exactly-once efectivo (a lo sumo un payout por par). Idempotency-Key en Stripe Transfer evita doble transferencia aunque el worker reintente. Es BD-backed, no solo lógica de app.

### 62. 🟡 Media
**Escenario.** El admin actualiza un producto subiendo una imagen NUEVA (actualizarProducto con file). La fila pasa de tener imagen=URL_vieja a imagen=URL_nueva. La URL vieja apuntaba a un objeto en el bucket 'piezas'.

**Problema.** El objeto viejo en storage queda huérfano para siempre (nadie lo referencia, pero sigue público y ocupando espacio). Repetir ediciones de imagen va dejando un rastro de objetos públicos huérfanos. Un reintento del update con la misma imagen nueva (UUID aleatorio) crea OTRO objeto, agravando.

**Solución.** Tras un update exitoso que cambió la imagen, borrar el objeto anterior: derivar el path desde la URL vieja (initial.imagen) y `supabase.storage.from('piezas').remove([pathViejo])` solo si el update tuvo éxito y la URL cambió. Combinar con el path determinista por id (`productos/${id}.<ext>`, upsert:true) del caso de subida: así la imagen nueva sobreescribe a la vieja en el MISMO path y no hay huérfano que limpiar.

**Idempotencia/seguridad.** Path determinista + upsert:true: reintentar la subida produce exactamente el mismo objeto (idempotente), sin acumulación. El remove del path viejo es idempotente (borrar dos veces el mismo path es no-op).

### 63. 🟡 Media
**Escenario.** requireAdmin() está memoizado con React cache() por request y hace getUser() (red) + rpc('is_admin'). En un Server Action mutante de larga duración (subida de 5MB + insert), la sesión podría expirar entre el chequeo inicial y el commit, o el token refrescarse.

**Problema.** No es un problema de duplicación, pero sí de consistencia: si la sesión expira a mitad del flujo subir-imagen-luego-insertar, la imagen pudo subirse (storage RLS pasó) y el insert fallar por sesión inválida -> objeto huérfano otra vez, y mensaje de error confuso. El reintento tras re-login vuelve a subir (nuevo UUID).

**Solución.** Aceptable que requireAdmin corra una vez por request (defensa en profundidad sobre RLS). Para la consistencia: aplicar el patrón 'fila primero o rollback compensatorio de storage' (caso de huérfanos). Y al reintentar, el path determinista por id evita acumulación. No reordenar el chequeo de auth; mantener requireAdmin al inicio de cada action (ya está).

**Idempotencia/seguridad.** El path determinista por id hace que el reintento tras re-login no acumule objetos. La authz se reevalúa en cada request (no se cachea entre requests), correcto. n/a para la expiración en sí (es de Auth, no de la mutación).

### 64. 🟢 Baja
**Escenario.** El admin edita un artesano y modifica solo el RFC (de NULL a un RFC válido) y guarda. actualizarArtesano hace .update(toRow()).eq('id', id) reescribiendo toda la fila, incluida la CLABE y el slug.

**Problema.** Si entre cargar el form y guardar, otra sesión cambió la CLABE de ese artesano, el update la pisa con el valor viejo que tenía el form (lost update sobre datos fiscales sensibles). Una CLABE incorrecta sobreescribiendo una correcta puede, en el futuro, dispersar dinero a una cuenta equivocada.

**Solución.** Mismo optimistic locking por updated_at — PERO artesanos NO tiene columna updated_at (solo created_at). Añadir `updated_at timestamptz not null default now()` + trigger touch_updated_at a artesanos (migración 0004) para habilitar el guard `.eq('updated_at', X)`. Mientras tanto, dado que CLABE/RFC son críticos, considerar una acción dedicada actualizarDatosFiscales que solo toque esas columnas.

**Idempotencia/seguridad.** Sin updated_at en artesanos hoy NO hay protección de concurrencia; añadir la columna + trigger es prerequisito para hacer el update condicional e idempotente ante reintento. Es bajo riesgo ahora (un solo admin, fase MVP) pero crítico antes de dispersar dinero real.

### 65. 🟡 Media
**Escenario.** crearProducto inserta con id = slug provisto por el admin (ej. 'tal-03'). El slug lo teclea el admin libremente; no se valida contra el patrón de los existentes ni se genera. Dos admins coordinando un lote pueden elegir el mismo siguiente número ('tal-03') sin saberlo.

**Problema.** El segundo pierde por PK (manejado), pero el flujo de 'asignar el siguiente id' es propenso a colisión y a reintento confuso. No hay generación server-side del id, así que la unicidad depende de coordinación humana + el respaldo del PK.

**Solución.** Mantener el PK como respaldo duro. Mejorar el flujo: al abrir 'nueva pieza', sugerir server-side el siguiente id libre por oficio (consultar max sufijo existente con ese prefijo y proponer +1), reduciendo colisiones. Si se quiere quitar la coordinación humana del todo, generar id determinista server-side y dejar el slug del admin solo como display. Validar en zod que el id no sea de los reservados/existentes es innecesario (la BD ya lo hace atómicamente).

**Idempotencia/seguridad.** El PK garantiza unicidad ante inserts concurrentes (BD serializa). La sugerencia server-side reduce la probabilidad de colisión pero NO sustituye al constraint: dos lecturas del 'siguiente libre' podrían coincidir, por eso el PK sigue siendo el respaldo autoritativo.

### 66. 🟡 Media
**Escenario.** Las Server Actions hacen revalidatePath('/admin/productos'), '/tienda', '/tienda/${id}' y luego redirect. Si el insert/update tuvo éxito pero revalidatePath o el redirect fallan (o el admin recarga durante la navegación), el admin podría reenviar el form.

**Problema.** redirect() lanza NEXT_REDIRECT; si el éxito ya ocurrió en BD pero el cliente reintenta (por reload o back+submit), en CREATE el reintento colisiona por PK (recuperable) pero en UPDATE el reintento reaplica el overwrite — y sin guard de updated_at, podría pisar un cambio intermedio de otra sesión. La revalidación parcial puede dejar /tienda mostrando estado viejo mientras /admin muestra el nuevo (inconsistencia de lectura temporal).

**Solución.** Para UPDATE: el guard de updated_at (caso 3) hace que el reintento del MISMO update afecte 0 filas (porque updated_at ya cambió) -> detectar y tratar como 'ya aplicado', no como conflicto, comparando contenido. Para la revalidación: agrupar las revalidaciones antes del redirect (ya está) y aceptar la consistencia eventual de /tienda (es lectura pública cacheada, no autoridad). No es necesario bloquear, sí evitar el reenvío con el patrón PRG ya presente (redirect = Post/Redirect/Get).

**Idempotencia/seguridad.** El patrón PRG (redirect tras POST) evita el reenvío por F5 en el caso normal. El guard updated_at cubre el reenvío manual. La inconsistencia de revalidación es transitoria y auto-corrige en el siguiente fetch (consistencia eventual aceptable para catálogo público).

### 67. 🟢 Baja
**Escenario.** El dashboard (metrics.ts) calcula ventas, comisión (12%) y retención simuladas de forma DETERMINISTA con un hash del id de pieza (función unit), no aleatoria. El admin crea/edita/borra piezas y artesanos durante una sesión.

**Problema.** No hay riesgo de duplicación (es solo lectura derivada), PERO al introducir el módulo real de órdenes, si los totales/retenciones se materializan en tablas y se recalculan por reintento de un job, recalcular con tasas distintas (RFC añadido después) sobre la misma orden ya liquidada daría cifras inconsistentes con lo ya dispersado/declarado al SAT.

**Solución.** Cuando exista el módulo fiscal: congelar (snapshot) la tasa de retención y los montos AL momento de order.paid en la fila de la orden/payout (no recalcular desde el RFC actual del artesano, que puede cambiar). El recálculo idempotente debe leer el snapshot, no las tasas vigentes. Hoy, dejar claro en metrics.ts que es simulación y no fuente de verdad fiscal (ya documentado en comentarios).

**Idempotencia/seguridad.** Materializar el snapshot de tasa/monto por orden hace que cualquier reproceso del job produzca el mismo resultado (idempotente respecto a cambios posteriores del RFC). Sin snapshot, el reproceso no sería idempotente ante cambios de catálogo. n/a para el dashboard simulado actual.


## Frontend / UX

### 68. 🔴 Alta · **⚡ implementar ya**
**Escenario.** El admin llena el formulario de crear pieza (/admin/productos/nuevo), pone precio 0, '15.50' con centavos, o slug 'TAL 03' con mayúsculas/espacios. El servidor rechaza con zod (productoCrearSchema). Vuelve la respuesta con state.errors y se muestran los mensajes de campo.

**Problema.** Los inputs de ProductoForm/ArtesanoForm usan defaultValue (uncontrolled). useActionState NO repuebla los inputs tras el re-render: el navegador conserva lo escrito SOLO porque React no recrea el nodo, pero si cualquier cosa fuerza remount (cambio de key, error boundary, file input que se limpia) se pierde. Peor: tras un re-render con nuevo state, los campos opcionales que el usuario borró/cambió no quedan reflejados como 'valor enviado', y la imagen seleccionada (file input) SIEMPRE se pierde al fallar el insert porque un File no persiste en el DOM. El admin debe re-seleccionar la foto en cada reintento de validación fallida.

**Solución.** Devolver los valores enviados en el ActionState (p.ej. state.values con Object.fromEntries(formData) menos campos sensibles/binarios) y pasarlos como defaultValue: `defaultValue={state.values?.precio_pesos ?? initial?.precio_centavos...}`. Para la imagen: tras subir, si el insert falla, conservar la URL ya subida en un input hidden `imagen_url` y mostrar el preview, de modo que un reintento no re-suba ni exija re-seleccionar. Alternativa mínima: validar en el cliente con el mismo zod (useActionState + onChange) para que el 90% de los errores no lleguen al servidor y no haya round-trip que arriesgue el File.

**Idempotencia/seguridad.** Conservar la URL de imagen ya subida en hidden evita re-subir el mismo archivo y crear blobs huérfanos en el bucket 'piezas' en cada reintento. El path usa crypto.randomUUID(), así que cada subida fallida deja un objeto sin referencia: el reintento debe reutilizar la URL, no generar otra.

### 69. 🔴 Alta · **⚡ implementar ya**
**Escenario.** El admin edita una pieza, sube una imagen nueva válida (se sube OK al bucket 'piezas'), pero el UPDATE de la fila falla (ej. error transitorio de red/Postgres, o conflicto). actualizarProducto sube primero (row.imagen = await subirImagen) y luego hace el update.

**Problema.** Si subirImagen tiene éxito pero el update falla, el objeto queda huérfano en Storage y el admin ve solo state.message='No se pudo guardar'. En reintentos, cada uno sube un blob nuevo (UUID distinto) => acumulación de imágenes huérfanas que nadie limpia, consumiendo el bucket público. No hay rollback de Storage si la escritura en la tabla falla.

**Solución.** Invertir el orden o compensar: (a) subir la imagen, (b) intentar el update, (c) si el update falla, ejecutar `supabase.storage.from('piezas').remove([path])` en el catch para no dejar huérfanos. Mejor aún: subir a un path determinista por producto (`productos/${id}.${ext}` con upsert:true en update) para que el reintento sobrescriba en vez de acumular. Exponer mensaje claro: 'La imagen se guardó pero no se aplicaron los cambios; reintenta.'

**Idempotencia/seguridad.** upsert:true con path determinista por id hace la subida idempotente: N reintentos => 1 objeto. Limpieza compensatoria (remove) cierra la fuga cuando el path es UUID aleatorio. El update de la fila ya es idempotente (.eq('id', id) + columnas fijas).

### 70. 🔴 Alta · **⚡ implementar ya**
**Escenario.** Listas /admin/productos y /admin/artesanos: no hay filtros por oficio/región/status/artesano ni búsqueda. listarProductos() hace SELECT de todas las filas con order created_at y las pinta en una <table>. Con 200+ piezas el admin no puede encontrar 'la pieza en borrador del taller X de Oaxaca'.

**Problema.** Sin filtros ni búsqueda la pantalla es inservible a escala; además trae todas las columnas (incluida descripción larga) de todas las filas en cada carga. No hay forma de aislar borradores vs publicados ni de ver solo las piezas de un artesano.

**Solución.** Filtros server-side por searchParams en la page (Server Component): `productos/page.tsx?status=borrador&oficio=...&artesano=<uuid>&q=...`. En listarProductos aceptar un filtro y traducirlo a Supabase: `.eq('status', f.status)`, `.eq('artesano_id', f.artesano)`, `.ilike('nombre', \`%${q}%\`)`, `.eq('oficio', f.oficio)`. UI: barra de <select> + <input search> que sea un <form method=GET> (sin JS) o que use router.replace con searchParams para deep-linking y back/forward. Para oficio/región/status usar enums/distinct conocidos; para artesano, el dropdown reusa listarArtesanosOpciones().

**Idempotencia/seguridad.** n/a (lectura). GET con searchParams es idempotente y compartible/bookmarkable por diseño.

### 71. 🟡 Media
**Escenario.** El admin aplica filtro '?q=Talavera' y luego edita o crea una pieza. Tras crearProducto el código hace redirect('/admin/productos') SIN searchParams.

**Problema.** El redirect descarta el contexto de filtro/búsqueda/página del admin. Vuelve a la lista completa sin filtro, perdiendo dónde estaba. Con paginación esto es peor: vuelve a la página 1.

**Solución.** Propagar el contexto: incluir un input hidden 'returnTo' con el querystring actual en el form, y en la action hacer `redirect(returnTo ?? '/admin/productos')` validando que returnTo empiece por '/admin/productos' (anti open-redirect). Validar con una whitelist de prefijos, nunca redirigir a URL arbitraria del cliente.

**Idempotencia/seguridad.** n/a (navegación). Validar returnTo contra whitelist evita que un POST manipulado redirija fuera del dominio.

### 72. 🟡 Media
**Escenario.** Listas sin paginación: listarProductos/listarArtesanos hacen SELECT sin .range(). Cuando haya cientos de piezas, la página renderiza una tabla gigante de una sola carga.

**Problema.** Sin paginación: payload enorme, render lento, sin límite. Supabase/PostgREST por defecto limita a 1000 filas, así que a partir de ahí el admin deja de ver registros SIN ningún aviso (truncamiento silencioso), creyendo que esos artesanos/piezas 'no existen'.

**Solución.** Paginación por searchParams: `?page=2`. En el data layer `.range(from, from+PAGE-1)` y pedir `{ count: 'exact' }` para saber el total. UI: controles Anterior/Siguiente como links GET y 'Mostrando 21–40 de 213'. Deshabilitar/ocultar Siguiente cuando from+PAGE >= count. Mantener filtros en los links de paginación.

**Idempotencia/seguridad.** n/a (lectura).

### 73. 🟡 Media · **⚡ implementar ya**
**Escenario.** El admin pulsa 'Eliminar pieza' o 'Eliminar artesano'. DeleteButton usa onSubmit con window.confirm; si confirma, dispara la Server Action que borra y redirige.

**Problema.** (1) window.confirm es bloqueante, no estilable, inaccesible y en algunos navegadores/incógnito puede estar suprimido (entonces borra sin confirmar). (2) No hay estado pending: el botón 'Eliminar' no se deshabilita ni muestra 'Eliminando…', así que un doble clic puede enviar dos POST. (3) eliminarArtesano no avisa que las piezas del artesano quedarán con artesano_id=NULL (ON DELETE SET NULL): el admin borra sin saber el efecto colateral en el catálogo.

**Solución.** Reemplazar window.confirm por un AlertDialog accesible (role=alertdialog, foco atrapado, Esc cancela, aria-describedby con el efecto). Usar useFormStatus/pending para deshabilitar el botón y mostrar 'Eliminando…'. En el diálogo de artesano, mostrar el conteo de piezas afectadas ('3 piezas quedarán sin artesano asignado'). Para destructivo crítico, requerir escribir el slug para confirmar.

**Idempotencia/seguridad.** El delete ya es idempotente por naturaleza (.eq('id', id): segundo borrado afecta 0 filas, no error). Pero deshabilitar el botón en pending evita doble POST y el flash de doble redirect. Garantía real: la operación es safe-to-retry porque DELETE de un id inexistente es no-op.

### 74. 🔴 Alta · **⚡ implementar ya**
**Escenario.** Concurrencia entre admins: dos administradores abren la MISMA pieza 'tal-01' en /admin/productos/tal-01. Admin A cambia el precio a 1200 y guarda; Admin B (con la versión vieja cargada) cambia la descripción y guarda 30s después.

**Problema.** actualizarProducto hace un UPDATE de TODAS las columnas (toRow) con .eq('id', id), sin control de versión. El guardado de B sobrescribe el precio de A con el valor viejo (last-write-wins silencioso). Lost update: el cambio de A desaparece sin que nadie lo note. Igual con artesanos (RFC/CLABE).

**Solución.** Optimistic concurrency: incluir un input hidden con `updated_at` cargado en el form y en el UPDATE añadir `.eq('updated_at', expectedUpdatedAt)`; si afecta 0 filas (`data.length===0` con .select()), devolver state.message='Otro administrador modificó este registro; recarga para ver los cambios.' La columna updated_at ya existe en productos con trigger. Para artesanos, agregar updated_at o usar un hash de campos.

**Idempotencia/seguridad.** El check `.eq('updated_at', expected)` convierte el update en condicional: un reintento del MISMO guardado (mismo expected) tras éxito afecta 0 filas la segunda vez => no re-sobrescribe. Garantiza que dos submits concurrentes no se pisen sin aviso. Respaldo a nivel BD (no solo app).

### 75. 🔴 Alta · **⚡ implementar ya**
**Escenario.** El admin envía el form de artesano con RFC mal formado o CLABE de 17 dígitos. zod los rechaza (refine) y devuelve state.errors. FieldError muestra el mensaje con aria-live=polite.

**Problema.** Accesibilidad: el <Input>/<select> NO recibe aria-invalid ni aria-describedby apuntando al FieldError. Un lector de pantalla no asocia el error con el campo ni anuncia 'inválido'. Además, al fallar la validación el foco NO se mueve al primer campo con error: el admin (sobre todo en móvil o con teclado) no sabe dónde está el problema y debe cazarlo visualmente.

**Solución.** En TextField/TextareaField/SelectField: cuando hay error, set `aria-invalid={!!error}`, `aria-describedby={error ? `${name}-error` : hint ? `${name}-hint`}` y dar `id={`${name}-error`}` al <p> de FieldError. El contenedor de error de formulario (state.message) debe tener role='alert'. Tras un submit fallido, mover foco al primer input con error con un useEffect que busque `[aria-invalid='true']` y .focus().

**Idempotencia/seguridad.** n/a (presentación/UX).

### 76. 🟡 Media · **⚡ implementar ya**
**Escenario.** El admin navega de la lista a /admin/productos (Server Component async que hace requireAdmin + listarProductos con dos round-trips a Supabase self-hosted por HTTP/Tailscale, latencia variable). No existe loading.tsx en (panel).

**Problema.** Sin loading.tsx ni Suspense la transición de ruta se bloquea hasta que el await resuelve: pantalla congelada/blank sin feedback. En enlace por Tailscale con latencia, esto se siente como app rota. Tampoco hay skeleton de tabla.

**Solución.** Añadir loading.tsx en cada segmento (productos, artesanos, dashboard) con un skeleton de tabla (filas con shimmer del mismo layout). Next App Router lo usa automáticamente como Suspense boundary durante la navegación. Para los filtros (que re-ejecutan el Server Component vía searchParams), mostrar estado pending con useTransition/router para no dejar la tabla 'muerta' mientras recarga.

**Idempotencia/seguridad.** n/a (lectura/UX).

### 77. 🔴 Alta · **⚡ implementar ya**
**Escenario.** El admin tiene el form de artesano abierto largo rato; la sesión GoTrue expira (self-hosted sin SMTP, cookies de sesión). Llena el form, da Guardar. requireAdmin() en la action llama redirect('/admin/login').

**Problema.** redirect() dentro de la Server Action provoca que el navegador navegue a /admin/login PERDIENDO todo lo escrito en el formulario (semblanza larga, RFC, CLABE, imagen seleccionada). El admin pierde el trabajo y, peor, ni siquiera ve un mensaje 'tu sesión expiró': solo aparece el login. Datos fiscales sensibles tecleados a mano se evaporan.

**Solución.** (1) Antes de que pase: refrescar token proactivamente o detectar expiración en cliente y avisar 'tu sesión está por expirar' con opción de re-login en un modal sin abandonar el form. (2) Si igual expira: en vez de redirect crudo, devolver ActionState con `{ message: 'Tu sesión expiró. Inicia sesión en otra pestaña y reintenta.', code: 'auth' }` para que el form preserve sus valores (combinado con state.values del caso 1). (3) Persistir borrador en sessionStorage por id de form, restaurar al volver. Nunca persistir RFC/CLABE en localStorage (sensibles) — usar sessionStorage y limpiarlo al guardar OK.

**Idempotencia/seguridad.** Tras re-login y reintento, los casos de UNIQUE (slug/id) protegen contra duplicados si el primer submit alcanzó a insertar. Borrador en sessionStorage no es dato persistente del lado servidor.

### 78. 🟡 Media · **⚡ implementar ya**
**Escenario.** El admin filtra '?oficio=Alfarería&status=agotado&q=jarro' y no hay coincidencias. La page ya tiene un empty state, pero es el genérico 'Aún no hay piezas. Crea la primera.'

**Problema.** El empty state actual asume 'no hay datos en absoluto'. Cuando hay datos pero el FILTRO no arroja resultados, el mensaje 'Aún no hay piezas, crea la primera' es engañoso: el admin cree que perdió las piezas o que debe crear una, cuando en realidad solo debe limpiar el filtro.

**Solución.** Distinguir dos vacíos: si hay searchParams activos => 'Sin resultados para estos filtros' + botón 'Limpiar filtros' (link a la ruta sin query). Si no hay filtros y count total = 0 => 'Aún no hay piezas. Crea la primera.' Determinarlo comparando si hay filtros aplicados, no solo items.length===0.

**Idempotencia/seguridad.** n/a (lectura).

### 79. 🟡 Media · **⚡ implementar ya**
**Escenario.** El admin escribe el slug de un artesano nuevo (form artesano) o el id de una pieza nueva ('tal-03'). No hay validación en vivo: solo descubre al hacer Submit si el slug ya existe (UNIQUE) o tiene formato inválido (mayúsculas/espacios), recibiendo 'Ya existe un artesano con ese slug' tras el round-trip.

**Problema.** El feedback de unicidad y formato del slug/id llega tarde (tras enviar todo el form, incl. subir imagen en el caso de pieza). El admin puede haber subido una imagen de 5MB que se desperdicia porque el id ya existía. La regex de slug solo se valida en el servidor.

**Solución.** (1) Validación de formato en vivo con el mismo regex de slug (onChange/onBlur), mostrando el error antes de enviar. (2) Para unicidad, un check optimista no bloqueante: al onBlur del slug, consultar `select id from productos where id = ?` (RLS admin lo permite) y avisar 'Ese identificador ya está en uso' sin garantizar — el UNIQUE en BD sigue siendo la autoridad. (3) Auto-sugerir slug desde el nombre (slugify) para reducir errores.

**Idempotencia/seguridad.** El constraint UNIQUE en productos.id (pk) y artesanos.slug es la garantía real ante carreras: dos admins creando 'tal-03' a la vez => uno recibe duplicate. El check en vivo es solo UX, no sustituye el constraint. El servidor ya mapea el error duplicate a un mensaje claro.

### 80. 🟡 Media
**Escenario.** El admin selecciona una imagen en el form de pieza. El preview se genera con URL.createObjectURL(f) y se guarda en estado. Cambia de imagen varias veces, o navega/cancela.

**Problema.** URL.createObjectURL crea blobs que nunca se liberan (no hay URL.revokeObjectURL). Cada cambio de archivo crea un blob nuevo que queda en memoria hasta cerrar la pestaña: fuga de memoria en sesiones largas de carga masiva de piezas. Además, si el archivo elegido supera 5MB o es de tipo no permitido, no hay feedback en cliente: el preview se muestra igual y el error solo aparece tras enviar (subirImagen lanza en servidor), desperdiciando el upload.

**Solución.** Revocar el blob anterior antes de crear uno nuevo y en cleanup del efecto: `URL.revokeObjectURL(prev)`. Validar tipo y tamaño en el onChange con los mismos límites del servidor (MAX_IMG 5MB, TIPOS jpg/png/webp) y mostrar error inline antes de permitir submit; limpiar el input si no pasa. El servidor mantiene la validación como autoridad (defensa en profundidad).

**Idempotencia/seguridad.** n/a (cliente). La validación servidor sigue siendo autoritativa contra un cliente manipulado.

### 81. 🔴 Alta · **⚡ implementar ya**
**Escenario.** Optimistic UI / doble submit en crear: el admin pulsa 'Crear' en el form de pieza con conexión lenta (Tailscale). El botón se deshabilita con `disabled={pending}` mientras useActionState está pending, pero el upload de imagen + insert tardan. El admin, impaciente, recarga o pulsa Enter de nuevo.

**Problema.** El disabled del botón cubre el doble-clic en el MISMO botón, pero NO cubre: (a) Enter repetido en un input, (b) recarga de la página re-enviando, (c) el caso de artesano que NO tiene UNIQUE en algún flujo. Para artesanos, slug es UNIQUE => la BD protege. Pero para piezas, si el primer submit subió la imagen y luego falló el insert por timeout percibido (aunque sí insertó), el reintento da 'Ya existe una pieza con ese identificador' — confuso: el admin cree que falló pero sí se creó.

**Solución.** Mostrar overlay/estado pending a nivel formulario (no solo botón) que bloquee toda la interacción mientras pending. Tras éxito, el redirect ya previene re-submit por recarga. Para el mensaje confuso de duplicate en reintento, detectar que el id ya existe Y pertenece a una creación reciente y redirigir a la edición de esa pieza ('Esta pieza ya se había creado') en vez de error. Idealmente, idempotency key de cliente.

**Idempotencia/seguridad.** El PK/UNIQUE de productos.id y artesanos.slug es el respaldo a nivel BD: doble submit nunca crea dos filas. Mejora UX: aceptar una idempotency key del cliente (hidden, crypto.randomUUID generado al montar el form) y un UNIQUE sobre ella, para que el segundo submit devuelva la misma pieza en vez de un error 'duplicate' críptico — alineado con la política de idempotencia del proyecto.

### 82. 🟢 Baja
**Escenario.** Responsive: las listas envuelven la <table> en `overflow-x-auto`. En móvil (admin revisando piezas desde el teléfono por Tailscale) la tabla de 6 columnas (imagen, pieza+id, oficio, precio, estatus, editar) se desborda horizontalmente.

**Problema.** overflow-x-auto evita romper el layout pero obliga a scroll horizontal incómodo en móvil; columnas clave (precio, estatus, acción Editar) quedan fuera de vista. La acción 'Editar' es un link de texto pequeño difícil de tocar (target < 44px). No hay vista de tarjetas alternativa.

**Solución.** Vista responsive: en <sm renderizar tarjetas (una por pieza) en vez de tabla, con nombre, id mono, precio, badge de estatus y botón Editar de tap target >=44px; en >=sm la tabla. Tailwind: `hidden sm:table` para la tabla y `sm:hidden` para la lista de tarjetas. Asegurar que los links de acción tengan padding suficiente.

**Idempotencia/seguridad.** n/a (presentación).

### 83. 🟡 Media
**Escenario.** El admin asigna un artesano a una pieza vía el SelectField 'Artesano', cuyas opciones vienen de listarArtesanosOpciones() (id+nombre). Mientras tanto, otro admin elimina ese artesano (eliminarArtesano), o el artesano fue pausado.

**Problema.** (1) Si el artesano se borra entre que se cargó el form y se guarda, el UPDATE manda artesano_id=<uuid borrado>; la FK productos.artesano_id es ON DELETE SET NULL pero NO previene insertar un uuid inexistente en el momento del update => violación de FK => error críptico 'No se pudo guardar: insert or update violates foreign key'. (2) El dropdown no distingue artesanos pausados de activos: el admin puede asignar una pieza a un artesano pausado sin darse cuenta, publicándola con un maker inactivo.

**Solución.** (1) Mapear el error de FK a un mensaje claro: 'El artesano seleccionado ya no existe; recarga la lista.' (2) En listarArtesanosOpciones incluir status y marcar en el <option> los pausados ('Nombre — pausado') o agruparlos con <optgroup>, para decisión informada. (3) Validar en la action que el artesano_id exista y esté activo si la regla de negocio lo exige.

**Idempotencia/seguridad.** n/a en concurrencia de borrado (la FK en BD es la autoridad: rechaza uuid inexistente). El zod ya valida formato uuid (anti-IDOR de formato); la existencia la garantiza la FK, no la app.

### 84. 🟡 Media
**Escenario.** El admin edita una pieza y borra el contenido de un campo opcional ya existente (p.ej. quita 'tecnica' que tenía valor, dejándolo vacío) y guarda. zod optText transforma '' en undefined; toRow lo pasa por n() => null.

**Problema.** El comportamiento es correcto (vaciar => NULL) pero NO es evidente para el admin: no hay confirmación visual de 'se borró este dato'. En el caso fiscal es delicado: si el admin accidentalmente borra el RFC o la CLABE (campos sensibles que alimentarán retenciones ~10.5% vs ~36%), el guardado los pone en NULL sin advertencia, cambiando potencialmente el régimen de retención del artesano sin ninguna alerta.

**Solución.** Para los campos fiscales (rfc/regimen_fiscal/clabe), advertir si se está vaciando un valor que antes existía: comparar initial vs enviado en cliente y mostrar confirmación 'Vas a borrar el RFC de este artesano. Esto afecta sus retenciones fiscales. ¿Continuar?'. Registrar el cambio (auditoría) en el servidor. Marcar visualmente estos campos como sensibles (ya hay fieldset 'confidencial') y considerar mostrar la CLABE enmascarada con un toggle 'mostrar' en lugar de texto plano.

**Idempotencia/seguridad.** n/a (la operación de update es idempotente). El riesgo es de pérdida de dato/UX, no de reintento.


## Fiscal / negocio (MX)

### 85. 🔴 Alta · **⚡ implementar ya**
**Escenario.** Admin captura el RFC de una persona MORAL (taller constituido como sociedad), p.ej. 'TME920327ABC' (12 caracteres: 3 letras + 6 fecha + 3 homoclave). El regex actual /^[A-ZÑ&]{3,4}\d{6}[A-Z0-9]{3}$/i exige 3-4 letras, así que acepta tanto 12 como 13. Pero el negocio de Tlachiwalis es de artesanos persona FÍSICA y luego querrá inferir tasa/CFDI por tipo.

**Problema.** El regex no distingue persona física (4 letras iniciales, 13 chars) de moral (3 letras, 12 chars). Un RFC de 12 con 4 letras (TMEX...) o uno de 13 con 3 letras se acepta indebidamente. No hay un campo derivado tipo_persona, así que el motor de retención/CFDI no sabe si es PF o PM (relevante para régimen aplicable y para Connect).

**Solución.** Separar dos patrones y derivar el tipo. zod: `rfc: optText.transform(v=>v?.toUpperCase()).refine(v=>v===undefined || /^[A-ZÑ&]{4}\d{6}[A-Z0-9]{3}$/.test(v) /*PF 13*/ || /^[A-ZÑ&]{3}\d{6}[A-Z0-9]{3}$/.test(v) /*PM 12*/,'RFC inválido')`. Añadir columna generada en BD: `alter table artesanos add column rfc_tipo text generated always as (case when rfc is null then null when length(rfc)=13 then 'fisica' when length(rfc)=12 then 'moral' end) stored;` y un CHECK que ate el largo: `check (rfc is null or rfc ~ '^[A-ZÑ&]{3,4}[0-9]{6}[A-Z0-9]{3}$')`. UX: mostrar 'Persona física/moral' detectado.

**Idempotencia/seguridad.** n/a (validación pura; la columna generada y el CHECK son deterministas, reaplicar el UPDATE da el mismo resultado).

### 86. 🔴 Alta · **⚡ implementar ya**
**Escenario.** Admin teclea el RFC en minúsculas o con espacios/guiones: 'godm 850101-h x9' o 'godm850101hx9'. El regex tiene flag /i, así que pasa, pero se guarda tal cual el usuario lo escribió en la columna `rfc`.

**Problema.** El RFC se persiste sin normalizar (minúsculas, espacios). Luego `tasaRetencion(rfc)` solo checa truthiness (funciona), pero cualquier comparación futura (UNIQUE, cruce con CFDI del PAC, búsqueda, validación SAT) fallará por inconsistencia de mayúsculas/whitespace. El SAT y los CFDI usan MAYÚSCULAS sin separadores.

**Solución.** Normalizar en zod ANTES de validar: `const rfc = z.string().trim().transform(v=>v.replace(/[\s-]/g,'').toUpperCase()).refine(...)`. Defensa en BD con normalización en el INSERT/UPDATE o un trigger BEFORE: `new.rfc := upper(regexp_replace(new.rfc,'[\s-]','','g'))`. Idem para CLABE (quitar espacios). En `toRow` ya pasa el valor normalizado por zod, así que basta corregir el schema.

**Idempotencia/seguridad.** n/a — la normalización es idempotente: aplicar upper/trim dos veces da lo mismo.

### 87. 🔴 Alta · **⚡ implementar ya**
**Escenario.** Dos artesanos distintos terminan con el MISMO RFC (error de captura, o un artesano dado de alta dos veces con slug diferente). No hay UNIQUE en `artesanos.rfc`.

**Problema.** RFC duplicado rompe la lógica de retenedor: la plataforma emitiría dos constancias de retención CFDI a un mismo RFC desde dos perfiles, y al integrar Stripe Connect (que exige RFC único por cuenta) habría colisión. También CLABE duplicada significaría dispersar a la misma cuenta por error.

**Solución.** Índices únicos parciales que ignoran NULL: `create unique index artesanos_rfc_uniq on public.artesanos (rfc) where rfc is not null;` y `create unique index artesanos_clabe_uniq on public.artesanos (clabe) where clabe is not null;`. En el Server Action, capturar el error de unique (código 23505) y devolver mensaje claro: hoy `crearArtesano` solo mapea 'duplicate'→slug; extender para distinguir constraint por `error.message`/`error.code` y devolver 'Ya existe un artesano con ese RFC/CLABE'.

**Idempotencia/seguridad.** El UNIQUE en BD es la garantía ante reintentos/concurrencia: dos requests simultáneos con el mismo RFC → uno gana, el otro recibe 23505 (no se crea duplicado). La normalización previa es obligatoria para que el UNIQUE funcione (sin ella 'godm...' y 'GODM...' burlarían el índice).

### 88. 🟡 Media
**Escenario.** Admin captura un RFC con fecha imposible en el bloque de 6 dígitos, p.ej. 'XAXX991332XXX' (mes 13, día 32) o 'XEXX010101000' (RFC genérico extranjero/público en general).

**Problema.** El regex `\d{6}` acepta cualquier 6 dígitos, incluyendo fechas inexistentes y los RFC genéricos 'XAXX010101000' (público en general) / 'XEXX010101000' (extranjeros). Un RFC genérico capturado como real significaría retención mal calculada y un CFDI emitido a un RFC inválido para ese artesano.

**Solución.** Validar la fecha embebida y rechazar genéricos en zod: extraer `AAMMDD`, construir Date y comprobar que mes∈1..12 y día válido; `refine` que excluya `['XAXX010101000','XEXX010101000']`. Pseudocódigo: `.refine(v=>{const m=v.match(/^[A-ZÑ&]{3,4}(\d{2})(\d{2})(\d{2})/);if(!m)return false;const mo=+m[2],da=+m[3];return mo>=1&&mo<=12&&da>=1&&da<=31;},'Fecha del RFC inválida')`. Marcar genéricos con bandera para que NUNCA califiquen como 'con RFC' a tasa 10.5%.

**Idempotencia/seguridad.** n/a (validación pura).

### 89. 🔴 Alta · **⚡ implementar ya**
**Escenario.** El campo `regimen_fiscal` es texto libre (optText). Admin escribe 'RESICO', 'resico', 'Régimen Simplificado de Confianza', '626', o lo deja vacío. Todos se guardan distinto.

**Problema.** Sin catálogo SAT, el régimen es basura inconsistente: el motor de retención no puede decidir la tasa por régimen (p.ej. RESICO PF retención de plataforma es 1.25% ISR, no 10.5%), y el CFDI de retenciones exige el código c_RegimenFiscal exacto. Strings libres impiden cualquier automatización fiscal.

**Solución.** Reemplazar texto libre por enum del catálogo SAT c_RegimenFiscal aplicable a PF: `z.enum(['605','606','607','608','610','611','612','614','615','616','621','625','626'])` con etiquetas reales (605 Sueldos y salarios; 606 Arrendamiento; 608 Demás ingresos; 611 Dividendos; 612 Actividades empresariales y profesionales; 614 Intereses; 615 Premios; 616 Sin obligaciones fiscales; 621 Incorporación Fiscal/RIF; 625 Régimen de las actividades empresariales con ingresos a través de plataformas tecnológicas; 626 RESICO). En BD: `check (regimen_fiscal is null or regimen_fiscal in ('605','606',...,'626'))`. UX: `<SelectField>` en lugar de `<TextField>` con value=código y label='626 — RESICO'. Definir un mapa `codigo→nombre` en `lib/admin/` como fuente única.

**Idempotencia/seguridad.** n/a (validación/catálogo).

### 90. 🟡 Media
**Escenario.** Admin asigna régimen 625 (plataformas tecnológicas) o 626 (RESICO) a un artesano, pero deja el RFC vacío; o asigna régimen 605 (Sueldos y salarios) a un artesano que vende productos (incongruente con actividad empresarial).

**Problema.** Hay inconsistencias cruzadas RFC↔régimen↔actividad: un régimen sin RFC es contradictorio (el régimen lo asigna el SAT al RFC); 605 'Sueldos y salarios' no aplica a quien vende artesanías por su cuenta. Esto produce CFDI de retención con régimen incorrecto y rechazo del PAC.

**Solución.** Validación cruzada a nivel de objeto en zod con `.superRefine`: si `regimen_fiscal` está presente exigir `rfc` presente (`if(data.regimen_fiscal && !data.rfc) ctx.addIssue({path:['regimen_fiscal'],message:'El régimen requiere RFC'})`). Lista blanca de regímenes plausibles para venta de artesanías (p.ej. 612/621/625/626) y advertencia suave (no bloqueo) si se elige otro. Documentar 'validar con contador'.

**Idempotencia/seguridad.** n/a.

### 91. 🔴 Alta · **⚡ implementar ya**
**Escenario.** La CLABE 'banamex' de un artesano se captura con un dígito mal: '002010077777777771' (18 dígitos, pasa el regex \d{18}) pero el dígito verificador no cuadra.

**Problema.** El regex actual `/^\d{18}$/` solo cuenta dígitos; NO valida el dígito de control (posición 18) por el algoritmo de ponderación 3-7-1 módulo 10 de la CLABE estandarizada. Una CLABE con un typo pasa la validación y, al dispersar el neto vía Stripe/SPEI, el dinero del artesano va a una cuenta equivocada o la transferencia se rechaza.

**Solución.** Implementar el verificador estándar CLABE en zod. Pesos por posición [3,7,1] cíclicos sobre los primeros 17 dígitos; `suma=Σ((d_i*peso_i) mod 10)`; `dv=(10-(suma mod 10)) mod 10`; debe igualar el dígito 18. `.refine(v=>{if(!v)return true;const p=[3,7,1];let s=0;for(let i=0;i<17;i++)s+=(+v[i]*p[i%3])%10;return (10-(s%10))%10===+v[17];},'CLABE: dígito verificador inválido')`. Reforzar en BD con un trigger o `CHECK` que invoque la misma lógica (función plpgsql). Validar también que los 3 primeros dígitos (código de banco) existan en catálogo del Banxico.

**Idempotencia/seguridad.** n/a (validación determinista). El CHECK en BD garantiza que reintentos/escrituras concurrentes no cuelen una CLABE inválida.

### 92. 🔴 Alta · **⚡ implementar ya**
**Escenario.** `tasaRetencion = (rfc) => (rfc ? 0.105 : 0.36)`. Un artesano se guarda con `rfc = ''` (cadena vacía) en lugar de NULL — por ejemplo si en el futuro un formulario manda string vacío sin pasar por el zod actual, o por una migración/seed.

**Problema.** Cadena vacía '' es falsy en JS, así que `tasaRetencion('')` da 0.36 (correcto por casualidad). PERO `artesanos.filter(a=>!a.rfc)` en `alertas.sinRfc` también la cuenta como sin RFC — y la columna nullable mezcla '' y NULL como estados 'sin RFC' distintos a nivel SQL (`rfc is null` no captura ''). Inconsistencia silenciosa entre la capa app y la BD sobre 'qué cuenta como sin RFC'.

**Solución.** Garantizar a nivel BD que vacío==NULL: `CHECK (rfc <> '' )` (rechaza '' explícito) o normalizar en trigger `nullif(trim(rfc),'')`. En `toRow`, `n(d.rfc)` ya convierte undefined→null y el zod optText convierte ''→undefined, así que el path actual es correcto; el riesgo es seeds/migraciones. Endurecer con el CHECK y migrar datos existentes: `update artesanos set rfc=nullif(trim(rfc),'') where rfc=''`.

**Idempotencia/seguridad.** n/a — `nullif(trim(...),'')` es idempotente.

### 93. 🔴 Alta · **⚡ implementar ya**
**Escenario.** La tasa de retención está hardcodeada como binaria 10.5% / 36% en `metrics.ts`, pero el régimen 626 (RESICO) de plataformas tiene retención de plataforma de 1.25% ISR, y la combinación ISR+IVA difiere según el RFC tenga o no IVA. El admin asigna RESICO pero el sistema sigue reteniéndole 10.5%.

**Problema.** La tasa solo depende de la presencia de RFC, ignorando el régimen fiscal. Para un artesano RESICO se sobre-retiene (10.5% vs 1.25%), reteniendo de más al artesano — error fiscal real con impacto monetario y de cumplimiento ante el SAT.

**Solución.** Convertir `tasaRetencion` en función de (rfc, regimen_fiscal): tabla de tasas por régimen. `function tasaRetencion(rfc, regimen){ if(!rfc) return RET_SIN_RFC; if(regimen==='626') return RET_RESICO_PLATAFORMA; return RET_CON_RFC_DEFAULT; }` con las tasas como constantes nombradas y comentario 'validar con contador'. A futuro (con backend) persistir la tasa aplicada por orden (snapshot) para que un cambio de régimen no recalcule retenciones históricas. Hoy en el dashboard simulado, al menos usar el régimen.

**Idempotencia/seguridad.** n/a hoy (cálculo de display). Cuando exista backend: snapshot inmutable de la tasa por orden = idempotente ante recálculos.

### 94. 🟡 Media
**Escenario.** En `computeMetrics`, `retencionMes` se acumula como float: `retencionMes += base * tasaRetencion(...)` dentro del loop, y solo al final `Math.round(retencionMes)`. `base = rev * (1 - 0.12)`, todo en centavos pero multiplicado por tasas fraccionarias.

**Problema.** Se opera dinero en centavos con aritmética de punto flotante y se redondea UNA sola vez al final. La retención por línea no está redondeada a centavo, así que la suma puede diferir de la suma de retenciones redondeadas por orden (lo que realmente se reportará en cada CFDI). Cuando exista el backend, retención_total ≠ Σ retención_por_orden → descuadres con el SAT.

**Solución.** Redondear a centavo entero en cada unidad de cálculo fiscal (por orden/por línea), no al final: `retencionMes += Math.round(base * tasa)`. Definir una sola util `centavos(montoFloat)=>Math.round(montoFloat)` y usarla en comisión, retención y neto. Regla de oro: el redondeo ocurre al nivel del documento fiscal (la orden), nunca acumulando floats. Validar que `neto = gmv - comision - retencion` con los tres ya redondeados (hoy `netoMes = gmvMes - comisionMes - retencionMes` con comisión/retención redondeadas pero retención redondeada en bloque, no por orden).

**Idempotencia/seguridad.** n/a (cálculo determinista). Importa para que el snapshot por orden sea estable.

### 95. 🟡 Media
**Escenario.** `fmtPesos(centavos) = '$' + Math.round(centavos/100).toLocaleString('es-MX')`. Un total de 12345 centavos ($123.45) se muestra como '$123'.

**Problema.** El formateador TRUNCA/redondea los centavos al mostrar montos. En un panel fiscal donde se exhiben comisión, retención y neto, perder centavos genera descuadres visuales (la suma mostrada no cuadra con el total) y desconfianza. Para montos fiscales los centavos importan.

**Solución.** Formatear con 2 decimales sin perder centavos: `new Intl.NumberFormat('es-MX',{style:'currency',currency:'MXN'}).format(centavos/100)`. Mantener la división por 100 pero delegar el formato a Intl con `minimumFractionDigits:2`. Reservar el redondeo a enteros solo para gráficas/labels donde se documente que es aproximado.

**Idempotencia/seguridad.** n/a (presentación).

### 96. 🟡 Media
**Escenario.** Admin marca un artesano `status='activo'`, le asigna productos publicados, pero deja RFC y CLABE en NULL. El dashboard ya tiene `alertas.sinRfc`/`sinClabe` pero NO impide publicar ni 'vender'.

**Problema.** Un artesano sin CLABE no puede recibir dispersión y sin RFC se le retiene 36%. Hoy solo es una alerta numérica; nada bloquea que sus piezas estén publicadas y generen ventas que después no se podrán liquidar correctamente. Riesgo operativo: dinero retenido sin poder dispersar.

**Solución.** Regla de negocio: para `status='activo'` exigir CLABE válida (no RFC, que puede faltar a 36%). Opción suave (recomendada ahora): warning prominente por artesano en su detalle y badge en la lista. Opción dura (futuro, con backend de pagos): `CHECK (status<>'activo' OR clabe is not null)` o validación en Server Action que impida activar sin CLABE. Mostrar en el form un aviso: 'Sin CLABE no se podrá dispersar; sin RFC se retiene 36%'.

**Idempotencia/seguridad.** n/a (regla de estado).

### 97. 🟢 Baja
**Escenario.** La homoclave (últimos 3 caracteres del RFC) se acepta con cualquier `[A-Z0-9]{3}`. Admin invierte dos caracteres de la homoclave por error de tecleo: 'GODM850101H9X' en vez de 'GODM850101HX9'.

**Problema.** El regex no valida el algoritmo de la homoclave (el SAT la calcula con un dígito verificador final basado en el nombre+fecha). Un RFC con homoclave incorrecta pasa la validación local y solo se descubre al rechazarlo el PAC al timbrar el CFDI, ya con retenciones calculadas.

**Solución.** El cálculo completo de la homoclave SAT es complejo (depende del nombre legal y tablas internas) y NO se puede validar 100% offline; pero el dígito verificador FINAL (posición 13/12) sí es algorítmico (módulo 11 sobre el RFC con tabla de valores A=10..Z=37). Implementar al menos esa verificación del último dígito como `refine`. Marcar el resto como 'no verificable offline' y delegar la validación fuerte al servicio del SAT/PAC cuando exista backend.

**Idempotencia/seguridad.** n/a (validación determinista del último dígito).

### 98. 🟡 Media
**Escenario.** Dos administradores editan el MISMO artesano casi a la vez: uno corrige el RFC, otro corrige la CLABE. Ambos cargaron el form con los valores viejos. El segundo `actualizarArtesano` que llega pisa con `update ... .eq('id', id)` el cambio del primero.

**Problema.** Last-write-wins sin control de concurrencia: el form reescribe TODA la fila (toRow incluye los 10 campos). El admin B, que no tocó el RFC, lo reescribe con el valor viejo, revirtiendo la corrección del admin A. En datos fiscales sensibles, una reversión silenciosa de RFC/CLABE es grave (se dispersa a cuenta equivocada).

**Solución.** Optimistic concurrency con la columna que ya existe parcialmente: añadir `updated_at` a artesanos (hoy solo productos lo tiene) y un trigger. Pasar `updated_at` como hidden en el form y en el UPDATE condicionar `.eq('id',id).eq('updated_at', prevUpdatedAt)`; si `count=0`, devolver 'El registro cambió, recarga'. Alternativa más simple: updates por campo (PATCH parcial) en lugar de reescribir toda la fila.

**Idempotencia/seguridad.** El guard `.eq('updated_at', prev)` hace el update idempotente/seguro ante concurrencia: solo aplica si nadie escribió en medio; un reintento con el mismo prev tras éxito afecta 0 filas (no re-pisa).

### 99. 🟡 Media · **⚡ implementar ya**
**Escenario.** Admin captura CLABE con 17 o 19 dígitos por un typo, o con un espacio en medio ('0020 1000 7777 7777 71'). Hoy `/^\d{18}$/` rechaza el espacio y los largos incorrectos, pero el mensaje 'La CLABE debe tener 18 dígitos' confunde cuando el problema es un espacio.

**Problema.** La CLABE pegada desde un estado de cuenta suele traer espacios/guiones de formato. El regex los rechaza con un mensaje sobre 'cantidad de dígitos', cuando el usuario SÍ tiene 18 dígitos. UX frustrante en un dato crítico para pagos, que lleva al admin a retecleas y arriesgar un error real.

**Solución.** Normalizar antes de validar (igual que RFC): `clabe: z.string().trim().transform(v=>v.replace(/[\s-]/g,'')).transform(v=>v===''?undefined:v).optional().refine(v=>v===undefined||/^\d{18}$/.test(v),'La CLABE debe tener 18 dígitos').refine(<verificador mod10>)`. Así se aceptan espacios/guiones de formato y solo se rechaza la longitud/dígitos reales. Guardar siempre normalizada (18 dígitos sin separadores).

**Idempotencia/seguridad.** n/a — normalización idempotente.

### 100. 🟢 Baja
**Escenario.** Admin asigna `moneda` distinta de MXN a un producto, o un futuro flujo crea precios en otra divisa, pero las retenciones (ISR/IVA) y los CFDI mexicanos solo aplican a MXN.

**Problema.** La columna `moneda` tiene default 'MXN' pero el CHECK no la restringe a MXN. Si entrara un producto en USD, el motor de retención (que asume centavos MXN) calcularía retenciones e ISR/IVA sobre un monto en otra divisa, produciendo CFDI y dispersión incorrectos.

**Solución.** Mientras el negocio sea solo MXN, fijarlo en BD: `alter table productos add constraint productos_moneda_mxn check (moneda = 'MXN')`. El Server Action ya no acepta `moneda` del cliente (no está en el whitelist toRow), lo cual es correcto; el CHECK lo blinda a nivel datos. Si en el futuro hay multi-divisa, el motor fiscal deberá convertir a MXN al tipo de cambio del día (DOF) antes de retener.

**Idempotencia/seguridad.** n/a (constraint estática).


## Storage / imágenes

### 101. 🔴 Alta · **⚡ implementar ya**
**Escenario.** Admin crea una pieza con imagen, pero el insert en productos falla (slug 'tal-01' duplicado, CHECK de precio, o caída de red post-upload). En crearProducto la imagen se sube ANTES del insert (línea 71) y nunca se limpia si el insert devuelve error (líneas 77-86).

**Problema.** Archivo HUÉRFANO permanente en el bucket 'piezas': ocupa espacio, queda accesible públicamente por su URL, y nunca se referencia desde ninguna fila. Con reintentos del admin se acumulan N copias por cada fallo.

**Solución.** Compensación: si el insert falla, borrar el objeto recién subido antes de retornar el error. Refactor: subir a un path determinístico por id `productos/${d.id}/principal.${ext}` y, en el catch del insert, `await supabase.storage.from('piezas').remove([path])`. Mejor aún: invertir el orden — insert primero con imagen=null, luego subir y update con la URL; si el update falla, borrar el objeto. Capturar el path (no solo la URL pública) para poder remove().

**Idempotencia/seguridad.** Path determinístico por id de producto + upsert:true hace que un reintegro del mismo producto sobrescriba en vez de duplicar. El remove() en el catch es idempotente (borrar algo ya borrado no falla de forma dura). El UNIQUE de productos.id sigue siendo la barrera contra doble insert.

### 102. 🔴 Alta · **⚡ implementar ya**
**Escenario.** Admin edita una pieza y sube una imagen nueva. actualizarProducto (línea 109) hace subirImagen() y pone row.imagen = nueva URL, luego update. La imagen ANTERIOR del bucket nunca se borra.

**Problema.** Cada reemplazo deja la imagen previa huérfana en el bucket público. Tras varias ediciones de la misma pieza hay 1 referenciada y K-1 basura, todas públicamente accesibles (URLs viejas que pudieron filtrarse a caches/CDN/terceros siguen sirviendo contenido).

**Solución.** Antes del update, leer la imagen actual: `const { data: prev } = await supabase.from('productos').select('imagen').eq('id', id).maybeSingle()`. Tras un update exitoso con nueva imagen, derivar el path de la URL previa y `storage.remove([prevPath])`. Si se usa path determinístico por id con upsert:true, el objeto se sobrescribe y no hay huérfano (solución preferida, evita el delete extra). Necesitas una función pathFromPublicUrl() que extraiga lo posterior a `/object/public/piezas/`.

**Idempotencia/seguridad.** Borrado del previo solo tras confirmar update OK (no borres antes de saber que la fila apunta a la nueva). remove() de un path inexistente es no-op. Con upsert determinístico, reintentos sobrescriben el mismo objeto: cero huérfanos por concurrencia.

### 103. 🔴 Alta · **⚡ implementar ya**
**Escenario.** Admin elimina una pieza. eliminarProducto (líneas 124-133) hace delete de la fila pero NO toca el bucket. Igual eliminarArtesano: borra el artesano (productos quedan con artesano_id NULL) y nunca limpia foto_url ni imágenes.

**Problema.** Al borrar la fila se pierde el único puntero (imagen) al objeto del bucket: queda huérfano IMPOSIBLE de rastrear desde la app (no hay fila que lo nombre). Fuga de espacio creciente y contenido público sin dueño.

**Solución.** En eliminarProducto, antes del delete: leer imagen, y tras delete exitoso, `storage.from('piezas').remove([path])`. Como red de seguridad ante huérfanos ya existentes y futuros fallos, agregar un job de barrido (cron/Edge Function) que liste objetos de 'piezas' y borre los que no aparezcan en `select imagen from productos`; correrlo con dry-run primero. Documentar que foto_url de artesano hoy es URL externa (no bucket), así que su borrado no aplica a 'piezas'.

**Idempotencia/seguridad.** Borrar fila y luego objeto: si el segundo paso falla, el barrido periódico lo recoge (la operación converge). remove() idempotente. El barrido debe excluir objetos subidos en los últimos ~minutos para no borrar uploads de un crearProducto en curso (ventana de carrera upload→insert).

### 104. 🔴 Alta
**Escenario.** El bucket 'piezas' es público de lectura (migración 0003, flag public=true + policy piezas_public_read). Cualquiera con la URL `/storage/v1/object/public/piezas/...` lee sin auth. La migración ya advierte: no subir nada sensible.

**Problema.** Riesgo de fuga si en el futuro alguien sube al bucket un comprobante fiscal, una foto del RFC/CLABE, una identificación del artesano o un PDF de contrato. Hoy rfc/regimen_fiscal/clabe viven en columnas con RLS, pero el patrón 'sube archivo' invita a meter PII fiscal al bucket equivocado.

**Solución.** Mantener invariante: 'piezas' SOLO para imágenes de producto públicas por diseño. Para cualquier documento sensible futuro, crear un bucket PRIVADO aparte (public=false) con policies is_admin() para select/insert y servir vía signed URLs de expiración corta. Reforzar validación de tipo en subirImagen (solo image/*). Añadir comentario en el form para que el admin no use el campo de imagen como adjunto de documentos.

**Idempotencia/seguridad.** n/a (control de diseño/política, no operación mutante).

### 105. 🟡 Media · **⚡ implementar ya**
**Escenario.** subirImagen valida file.type contra ['image/jpeg','image/png','image/webp'] y deriva ext de file.name (línea 29). Ambos los controla el cliente: puede mandar un .svg renombrado a .jpg con Content-Type image/jpeg, o un HTML con doble extensión.

**Problema.** El MIME y la extensión son declarados por el cliente, no verificados contra los magic bytes reales. Un SVG servido desde el bucket público puede contener <script> (XSS si se abre directo en el navegador, no vía next/image). Archivo con ext arbitraria o sin punto cae al fallback 'jpg' y miente sobre su tipo.

**Solución.** Validar los magic bytes del File en el servidor: leer los primeros bytes (`const head = new Uint8Array(await file.slice(0,16).arrayBuffer())`) y comprobar firmas (JPEG FF D8 FF, PNG 89 50 4E 47, RIFF/WEBP). Rechazar SVG explícitamente. Derivar la extensión del tipo DETECTADO, no de file.name. A nivel bucket, fijar allowed_mime_types y file_size_limit en storage.buckets para 'piezas'.

**Idempotencia/seguridad.** n/a (validación pura, sin estado).

### 106. 🟡 Media · **⚡ implementar ya**
**Escenario.** El límite de 5 MB (MAX_IMG) y los tipos solo se aplican en la Server Action. El bucket 'piezas' se creó sin file_size_limit ni allowed_mime_types (migración 0003 solo hace insert id/name/public).

**Problema.** La barrera de tamaño/tipo es solo lógica de app. Un admin (o un token de admin comprometido) que llame directo al endpoint de Storage con la anon/sesión salta subirImagen() y sube un archivo de 500 MB o un tipo arbitrario: el RLS piezas_admin_insert solo exige is_admin(), no acota tamaño ni MIME.

**Solución.** Configurar el bucket como respaldo duro: `update storage.buckets set file_size_limit = 5242880, allowed_mime_types = array['image/jpeg','image/png','image/webp'] where id='piezas';` (en una migración 0004, idempotente). Así Storage rechaza por sí mismo lo que la app dejaría pasar. La validación de app se conserva para mensajes de error amables.

**Idempotencia/seguridad.** Migración idempotente (update por id). El constraint del bucket aplica en cada upload sin importar reintentos.

### 107. 🔴 Alta · **⚡ implementar ya**
**Escenario.** El campo 'Foto (URL)' del artesano (artesano-form) acepta cualquier URL http/https (schema foto_url solo valida /^https?:\/\/.+/). Esa URL externa se guarda en artesanos.foto_url y se renderiza. next.config.ts solo permite remotePatterns para supabase.glowel.com.mx:8000.

**Problema.** URLs ROTAS / next/image que falla: si foto_url apunta a un host distinto al permitido, next/image (optimizado) lanza error 400 'hostname not configured under images'. Donde se use <Image> sin unoptimized (p.ej. FramedImage), la página del artesano truena o muestra imagen rota. Además es vector de SSRF/leak: el optimizador del servidor hará fetch a un host arbitrario controlado por quien edite.

**Solución.** Decidir el modelo: (a) si las fotos de artesano deben vivir en el bucket, cambiar el campo a un file input que use subirImagen() y guardar una URL del bucket permitido; (b) si se permiten URLs externas, validarlas contra una allowlist de hosts en el schema zod y añadir esos hosts a remotePatterns, o renderizarlas con `unoptimized` para no pasar por el optimizador (evita SSRF). Recomendado (a): unificar todo en el bucket controlado.

**Idempotencia/seguridad.** n/a (validación/config). Si se migra a bucket, aplica la misma compensación de huérfanos que productos.

### 108. 🟡 Media
**Escenario.** Stack self-hosted por HTTP sobre Tailscale (supabase.glowel.com.mx:8000). Todas las imágenes públicas y previews dependen de que ese host esté arriba y accesible desde el visitante.

**Problema.** URLs rotas / host caído: si el contenedor de Storage cae, la VPN se desconecta, o el visitante no está en la tailnet, TODAS las imágenes (productos y previews admin) fallan en bloque. next/image optimizado además cachea el primer fetch fallido. Servir contenido público por HTTP plano también expone las imágenes a MITM/cache envenenado.

**Solución.** Para contenido público real, no servir imágenes desde un host en tailnet: ponerlas detrás de un reverse proxy/CDN público con HTTPS (mismo origen del sitio o subdominio con TLS). Mientras siga en HTTP interno, fijar un placeholder/fallback en los componentes de imagen (onError → imagen local de respaldo) y considerar `unoptimized` para no envenenar la cache del optimizador con 404s. Añadir healthcheck del endpoint de Storage.

**Idempotencia/seguridad.** n/a (infra/disponibilidad).

### 109. 🟢 Baja · **⚡ implementar ya**
**Escenario.** El path de subida es `productos/${crypto.randomUUID()}.${ext}` con upsert:false. El nombre es aleatorio por upload.

**Problema.** COLISIÓN de nombres: prácticamente imposible con UUIDv4, pero el diseño actual produce un objeto NUEVO por cada upload (nunca reusa path), lo que es la causa raíz de los huérfanos en reemplazo (cada edición = path nuevo, el viejo queda). El upsert:false además convierte la (improbable) colisión en un error de upload no diferenciado.

**Solución.** Adoptar path determinístico ligado al recurso: `productos/${productoId}/principal.${ext}` con upsert:true. Esto (1) elimina huérfanos por reemplazo —se sobrescribe—, (2) hace el upload idempotente ante reintentos, (3) agrupa los assets por pieza para borrado en cascada al eliminar. Mantener un sufijo de versión o cache-busting (?v=updated_at) si hace falta invalidar CDN. UUID aleatorio solo si se quieren conservar versiones históricas a propósito.

**Idempotencia/seguridad.** Path determinístico + upsert:true = upload idempotente: dos envíos del mismo archivo producen un solo objeto. Resuelve la mayoría de los casos de huérfanos de raíz.

### 110. 🟡 Media · **⚡ implementar ya**
**Escenario.** Las fotos llegan tal cual desde el teléfono/cámara del admin o del artesano. subirImagen sube el File sin procesarlo. Los JPEG de cámara llevan metadatos EXIF.

**Problema.** EXIF/PII en fotos: el JPEG puede incluir geolocalización GPS (revela la ubicación exacta del taller/casa del artesano), número de serie de cámara, fecha y a veces miniatura embebida con contenido distinto. Como el bucket es público, cualquiera descarga el JPEG y extrae el GPS → fuga de PII de ubicación del artesano.

**Solución.** Re-encodear/strippear metadatos en el servidor antes de subir: pasar el buffer por sharp (`sharp(buf).rotate().jpeg({quality:82}).toBuffer()` — rotate() aplica la orientación EXIF y el re-encode descarta el resto de metadatos), o por la pipeline de optimización. Esto además normaliza tamaño/orientación. Subir el buffer saneado, no el File original.

**Idempotencia/seguridad.** Determinista: re-encodear dos veces el mismo origen produce salida equivalente; combinado con path determinístico, los reintentos sobrescriben sin duplicar.

### 111. 🔴 Alta · **⚡ implementar ya**
**Escenario.** Caso intermedio de crearProducto: la imagen sube OK (línea 71) pero el proceso se interrumpe entre el upload y el insert (timeout del Server Action, navegador cerrado, deploy en caliente, error de red), o el insert nunca se ejecuta.

**Problema.** Imagen sube pero la pieza NO se crea: huérfano sin ninguna fila que lo referencie, indetectable desde la app. Variante del caso de fallo de insert pero por interrupción, no por error retornado, así que ni siquiera entra al catch.

**Solución.** Patrón insert-primero: crear la fila con imagen=null dentro de la misma action ANTES de subir; luego subir a path por id y hacer update de la URL. Si la action muere tras el insert, queda una pieza sin imagen (estado válido y editable), no un objeto fantasma. El barrido periódico de huérfanos (mismo del caso de borrado) cubre los uploads que quedaron sin update, ignorando los recientes para no pisar uploads en curso.

**Idempotencia/seguridad.** Path por id + upsert:true: si el admin reintenta el alta del mismo id, el upload sobrescribe y el insert choca con UNIQUE(id) → mensaje 'ya existe', sin duplicar archivo. El barrido converge el estado.

### 112. 🟡 Media
**Escenario.** Dos pestañas/dos admins editan el MISMO producto casi a la vez, cada una subiendo una imagen distinta. Con path aleatorio (diseño actual) se crean dos objetos; ambos updates corren sin control de versión.

**Problema.** Concurrencia: gana el último update (last-write-wins) y la fila apunta a una de las dos imágenes; la otra queda HUÉRFANA. Si se adopta path determinístico por id sin cuidado, los dos uploads se pisan y la fila podría apuntar a un objeto que el otro update ya sobrescribió (imagen mostrada ≠ esperada).

**Solución.** Para el huérfano, el barrido periódico lo resuelve. Para la consistencia, usar control optimista: añadir columna version/lock o comparar updated_at en el WHERE del update (`.eq('updated_at', prevUpdatedAt)`) y avisar 'la pieza cambió, recarga'. Con path determinístico por id, la imagen final siempre corresponde al último upload físico, alineada con last-write-wins de la fila.

**Idempotencia/seguridad.** El check optimista (updated_at en el WHERE) hace que un reintento ciego no pise cambios ajenos. Path determinístico asegura un único objeto por pieza pese a uploads concurrentes.

### 113. 🟡 Media · **⚡ implementar ya**
**Escenario.** En actualizarProducto la imagen nueva sube OK (línea 109) pero el `update` de la fila falla (línea 115-116): RLS, validación de BD, o caída. La función retorna error pero la fila sigue apuntando a la imagen vieja.

**Problema.** Doble huérfano: la imagen NUEVA quedó subida y no referenciada (huérfana), y la VIEJA sigue en uso. El admin ve el error, reintenta, y se sube OTRA imagen nueva → se acumulan huérfanos por cada reintento fallido del update.

**Solución.** Subir a path determinístico por id con upsert:true (un reintento sobrescribe el mismo objeto, no acumula) y NO borrar la vieja hasta que el update confirme éxito. Si el update falla, dejar la fila intacta apuntando a la vieja; el objeto subido sobrescribió siempre el mismo path así que no hay acumulación. Solo tras update OK, borrar el path previo si difería.

**Idempotencia/seguridad.** upsert:true en path fijo por id = reintentos idempotentes (cero acumulación). El borrado del previo condicionado a update OK evita perder la imagen en uso si el update fracasa.

### 114. 🟢 Baja
**Escenario.** FramedImage (componente público) usa next/image SIN unoptimized, mientras el preview del form admin sí usa unoptimized. remotePatterns en next.config solo cubre exactamente http + supabase.glowel.com.mx + puerto 8000 + pathname /storage/v1/object/public/**.

**Problema.** Si cambia el host/puerto del Storage self-hosted (migración de infra, HTTPS en 443, nuevo dominio), las URLs guardadas en la BD apuntan al host viejo y/o el optimizador rechaza el nuevo por no estar en remotePatterns → next/image 400 y todas las piezas se ven rotas. Acoplamiento frágil entre URLs absolutas persistidas y la config de imágenes.

**Solución.** Guardar en la BD el PATH del objeto (`productos/<id>/principal.jpg`), no la URL pública absoluta, y construir la URL en render desde una env var (NEXT_PUBLIC_SUPABASE_URL). Así un cambio de host es config, no migración de datos. Mantener remotePatterns alineado con esa env. Para self-hosted en evolución, considerar un loader de imágenes custom o unoptimized en FramedImage como en el preview, para no depender del optimizador.

**Idempotencia/seguridad.** n/a (decisión de modelado de datos/config).

### 115. 🟡 Media · **⚡ implementar ya**
**Escenario.** El path de subida deriva ext de file.name con `file.name.split('.').pop()` (línea 29). Un nombre como 'foto' (sin punto), 'foto.JPG', 'foto.tar.gz' o con caracteres unicode/espacios produce ext rara o cae a 'jpg'. El nombre original del archivo no se sanitiza.

**Problema.** Nombre con extensión engañosa o ausente: el objeto puede terminar con una ext que no corresponde al contenido (p.ej. '.jpg' fijo para un PNG real), causando que algunos clientes interpreten mal el Content-Type al servir directo desde el bucket público. No es colisión, pero sí inconsistencia tipo/nombre que confunde caches y descargas.

**Solución.** No confiar en file.name para nada del path. Derivar la extensión del tipo DETECTADO por magic bytes (jpeg→jpg, png→png, webp→webp) y fijar contentType al detectado, no a file.type. Con path determinístico `productos/<id>/principal.<extDetectada>` el nombre original del cliente nunca toca el storage. Si dos formatos para el mismo id coexisten (cambió de png a jpg), borrar el path previo de la otra extensión.

**Idempotencia/seguridad.** Ext determinada por contenido + path por id = estable entre reintentos. Limpieza del path con ext anterior evita un huérfano por cambio de formato del mismo producto.


## Catálogos / datos pre-rellenados

### 116. 🔴 Alta · **⚡ implementar ya**
**Escenario.** Admin captura el regimen fiscal del artesano. El form usa TextField libre (artesano-form.tsx linea 95-99) y la columna artesanos.regimen_fiscal es text nullable sin CHECK. Un admin escribe 'RESICO', otro 'Resico', otro 'Regimen Simplificado de Confianza', otro '626'.

**Problema.** El futuro motor de retenciones (ISR/IVA: con RFC ~10.5%, sin RFC ~36%) y la emision de CFDI por PAC necesitan la CLAVE numerica del catalogo c_RegimenFiscal del SAT (601, 605, 612, 621, 626...). Texto libre inconsistente hace imposible mapear la tasa correcta y el CFDI sera rechazado por el PAC. Tambien rompe agrupaciones/reportes.

**Solución.** Crear catalogo SAT como tabla seed: create table public.sat_regimen_fiscal (clave text primary key, descripcion text not null, persona_fisica bool not null default true, persona_moral bool not null default false). Seed con las claves vigentes (601,603,605,606,607,608,610,611,612,614,615,616,620,621,622,623,624,625,626,627,628,629,630). Cambiar la columna a guardar la clave: ALTER TABLE artesanos ADD CONSTRAINT regimen_fk FOREIGN KEY (regimen_fiscal) REFERENCES sat_regimen_fiscal(clave). En el form reemplazar TextField por SelectField poblado desde la tabla (en page.tsx server component, listar sat_regimen_fiscal); zod: regimen_fiscal: z.string().regex(/^[0-9]{3}$/).optional(). RLS: select to authenticated/anon sobre el catalogo (no es sensible).

**Idempotencia/seguridad.** Seed con on conflict (clave) do nothing; reejecutar la migracion no duplica. FK garantiza que no se inserte una clave inexistente aunque el form sea manipulado.

### 117. 🔴 Alta · **⚡ implementar ya**
**Escenario.** Al guardar un producto, toRow() (productos/actions.ts linea 40-54) copia maker/oficio/region tal como vienen del form. El admin selecciona un artesano en el SelectField (producto-form.tsx linea 74-83) pero escribe a mano maker='Talavera Hnos', oficio y region en TextFields separados, que pueden no coincidir con el artesano elegido.

**Problema.** maker, oficio y region son denormalizados de artesanos para lectura publica. Quedan desincronizados: artesano_id apunta a 'Macrina Pacheco' pero maker dice 'Talavera Hnos'. La pieza publica muestra autor/oficio/region equivocados. No hay ninguna validacion de consistencia.

**Solución.** Auto-rellenar desde el artesano en el servidor (autoridad), no confiar en el form. En crearProducto/actualizarProducto, tras validar, si d.artesano_id no es null: const { data: art } = await supabase.from('artesanos').select('nombre,oficio,region').eq('id', d.artesano_id).maybeSingle(); y construir el row con maker = art.nombre, oficio = art.oficio, region = art.region (ignorar lo que mando el cliente para esos tres campos cuando hay artesano). En el form, cuando hay artesano seleccionado, mostrar maker/oficio/region como readOnly derivados (UX) y solo permitir override manual si artesano_id == '' (sin asignar).

**Idempotencia/seguridad.** n/a (operacion determinista: el mismo artesano produce el mismo row en cada reintento).

### 118. 🔴 Alta · **⚡ implementar ya**
**Escenario.** Admin crea un artesano sin oficio ni region (ambos opcionales, optText -> null en artesanos). Luego crea un producto y lo asigna a ese artesano. Con el auto-rellenado del caso anterior, oficio=null y region=null se intentan escribir en productos.

**Problema.** productos.oficio y productos.region son NOT NULL en el schema (0001_init.sql lineas 29-30). Auto-rellenar desde un artesano con esos campos en null causa null value violates not-null constraint y el insert falla con error crudo de Postgres, confundiendo al admin.

**Solución.** Validar la precondicion en el server action antes del insert: si se asigna artesano_id y el artesano tiene oficio o region null, devolver { message: 'El artesano "X" no tiene oficio/region capturados; completalos antes de asignarle piezas.' } con link a editar el artesano. Alternativamente, mantener oficio/region del form como fallback cuando el artesano los tiene null. Decidir politica: recomendado exigir que oficio/region del artesano esten completos (volverlos requeridos en el form de artesano una vez exista catalogo).

**Idempotencia/seguridad.** n/a (validacion pura, sin efectos secundarios).

### 119. 🔴 Alta · **⚡ implementar ya**
**Escenario.** region se captura como TextField libre tanto en artesano-form como en producto-form. El seed ya tiene 'Edo. de Mexico' (linea 12) mientras un admin nuevo escribira 'Estado de Mexico', 'Mexico', 'EDOMEX' o 'CDMX' vs 'Ciudad de Mexico'.

**Problema.** Sin catalogo controlado de los 32 estados, los filtros por region (productos_region_idx existe pero indexa basura inconsistente), los agrupamientos del dashboard y la navegacion publica por estado se fragmentan. 'Oaxaca' y 'oaxaca' cuentan como dos regiones.

**Solución.** Tabla catalogo: create table public.estados_mx (clave text primary key, nombre text not null) seed con las 32 entidades oficiales (codigo INEGI 01..32 o abreviatura) incluyendo 'Ciudad de Mexico' y 'Estado de Mexico' canonicos. Cambiar region a SelectField en ambos forms poblado desde estados_mx. zod region: z.enum([...32 claves]) o FK. Migracion de normalizacion para datos legacy: UPDATE artesanos SET region='Estado de Mexico' WHERE region IN ('Edo. de Mexico','EDOMEX','Mexico'); idem productos. Mantener region en productos como texto denormalizado pero validado contra el catalogo.

**Idempotencia/seguridad.** Seed con on conflict do nothing. La migracion de normalizacion es idempotente (UPDATE ... WHERE region IN (...variantes) deja el valor canonico; reejecutar no cambia nada porque ya es canonico).

### 120. 🟡 Media · **⚡ implementar ya**
**Escenario.** oficio es texto libre. El seed tiene 'Barro negro', 'Talavera', 'Alebrijes', 'Telar de cintura', 'Cesteria'. Un admin nuevo escribira 'barro negro', 'Barro Negro', 'Alebrije' (singular) o un oficio totalmente nuevo no contemplado.

**Problema.** Tension entre catalogo controlado (consistencia, filtros, taxonomia artesanal coherente) y la realidad de que el universo de oficios artesanales mexicanos es abierto y crece. Un enum cerrado bloquea agregar oficios legitimos; texto 100% libre fragmenta.

**Solución.** Catalogo controlado pero extensible (no enum): create table public.oficios (slug text primary key, nombre text not null, activo bool default true). Seed con los oficios actuales normalizados. En el form: SelectField con las opciones del catalogo + opcion '+ Nuevo oficio' que inserta en el catalogo (solo admin via RLS is_admin()). zod valida contra slugs existentes; agregar un oficio es una accion explicita, no un typo. NO usar CHECK/enum porque exigiria migracion para cada oficio nuevo.

**Idempotencia/seguridad.** Insert de oficio nuevo con UNIQUE(slug) e insert-or-ignore: si dos admins crean 'vidrio-soplado' a la vez, el UNIQUE evita duplicado y el segundo reusa el existente.

### 121. 🟡 Media · **⚡ implementar ya**
**Escenario.** RFC se valida con regex case-insensitive (schemas.ts linea 27-30: /i) pero se guarda tal cual lo escribio el admin: 'caup920101ab9' en minusculas o 'CaUp920101Ab9' mixto.

**Problema.** El SAT y el CFDI exigen el RFC en MAYUSCULAS. Guardar minusculas/mixto rompe el matching contra el padron del SAT, la emision de CFDI de retenciones y cualquier comparacion de unicidad de RFC. Ademas no hay UNIQUE en rfc: dos artesanos pueden tener el mismo RFC.

**Solución.** Normalizar en zod con transform: rfc: optText.transform(v => v?.toUpperCase().replace(/\s+/g,'')).refine(regex). Igual para clabe (quitar espacios). Agregar indice unico parcial: CREATE UNIQUE INDEX artesanos_rfc_uniq ON artesanos (upper(rfc)) WHERE rfc IS NOT NULL; para impedir dos artesanos con el mismo RFC. Migracion legacy: UPDATE artesanos SET rfc = upper(rfc) WHERE rfc IS NOT NULL AND rfc <> upper(rfc).

**Idempotencia/seguridad.** El UNIQUE index es el respaldo en BD (no solo logica de app): un reintento o concurrencia que intente duplicar RFC falla en la BD. La normalizacion upper() es idempotente.

### 122. 🟡 Media
**Escenario.** El admin borra un artesano. eliminarArtesano (artesanos/actions.ts linea 68) hace delete; la FK productos.artesano_id es ON DELETE SET NULL. Las piezas de ese artesano quedan con artesano_id=null pero maker='Familia Ortega', oficio='Alebrijes', region='Oaxaca' congelados.

**Problema.** Quedan productos huerfanos publicados con autor denormalizado de un artesano que ya no existe. El admin no recibe advertencia de cuantas piezas quedaran huerfanas. Si despues edita esa pieza, el SelectField de artesano vuelve a '— Sin asignar —' pero maker sigue mostrando el viejo nombre, sin forma de re-vincular consistentemente.

**Solución.** UX: antes de eliminar, el delete-button debe consultar count de productos del artesano y pedir confirmacion: 'Este artesano tiene N piezas; quedaran sin autor asignado. Continuar?'. Mejor: ofrecer reasignar las piezas a otro artesano o pasarlas a status='borrador' en la misma transaccion. Implementar como server action que: 1) cuenta productos, 2) si N>0 exige decision (reasignar_a uuid | despublicar | confirmar_huerfanas). Considerar bloquear el delete si el artesano tiene rfc/clabe (datos fiscales) y en su lugar forzar status='pausado'.

**Idempotencia/seguridad.** El delete por id es idempotente (segundo delete no afecta filas). La reasignacion masiva UPDATE productos SET artesano_id=:nuevo WHERE artesano_id=:viejo es idempotente.

### 123. 🟡 Media · **⚡ implementar ya**
**Escenario.** Admin cambia el artesano asignado de una pieza existente (de 'Talavera Hnos' a 'Macrina Pacheco') via el SelectField en edicion. actualizarProducto -> toRow copia el maker que sigue en el form ('Talavera Hnos').

**Problema.** Al reasignar artesano, los campos denormalizados maker/oficio/region NO se actualizan automaticamente: el form conserva los valores del initial. La pieza queda atribuida a Macrina Pacheco (FK) pero sigue diciendo 'Talavera Hnos' en publico. Es el mismo bug de sincronia pero en el flujo de edicion/reasignacion.

**Solución.** Misma fuente de verdad que el caso de auto-rellenado: en actualizarProducto, si artesano_id viene definido, re-leer nombre/oficio/region del artesano y sobreescribir maker/oficio/region en el row, ignorando lo que trae el form. En el cliente, onChange del SelectField de artesano debe re-poblar (o limpiar a readOnly) los campos maker/oficio/region para que el admin vea el cambio antes de guardar. Pasar las opciones de artesano con sus oficio/region embebidos (ArtesanoOpcion extendido) para resolver sin round-trip.

**Idempotencia/seguridad.** n/a (determinista: re-leer el artesano produce el mismo resultado).

### 124. 🟢 Baja
**Escenario.** status de producto es un SelectField con default 'borrador' en el form (producto-form.tsx linea 119), pero la columna tiene default 'publicado' (0001_init.sql linea 38). Un producto creado sin tocar el select se guarda como 'borrador' desde el form, pero un insert directo/legacy quedaria 'publicado'.

**Problema.** Inconsistencia de default entre UI y BD. Mas importante: no hay regla que impida publicar (status='publicado') una pieza con datos incompletos (sin imagen, sin descripcion, sin precio sensato, o con artesano sin RFC). El anon ve productos publicados directamente por RLS (productos_publicados_select).

**Solución.** Definir 'requisitos de publicacion' validados en el server action SOLO cuando status='publicado': imagen no null, descripcion presente, precio_centavos>0, y artesano_id asignado. Si falta algo, devolver error de campo y forzar status='borrador'. Esto es una regla de negocio del catalogo, no solo del CHECK. Alinear el default del form con la intencion del producto (recomendado 'borrador' para que nada se publique a medias por accidente, lo cual ya hace el form; documentarlo).

**Idempotencia/seguridad.** n/a (validacion pura).

### 125. 🟡 Media
**Escenario.** El catalogo SAT de regimen fiscal distingue persona fisica vs moral. Talavera Hnos / Coop. Vida Nueva (sufijos de razon social/cooperativa en el seed) son personas morales; Macrina Pacheco, Rosa Hernandez son fisicas. El admin podria asignar un regimen de persona moral (601) a una persona fisica.

**Problema.** Asignar un regimen incompatible con el tipo de persona del RFC produce CFDI invalido (el PAC valida regimen contra el tipo de RFC: 12 caracteres = moral, 13 = fisica). Tambien afecta que tasas de retencion aplican. Sin validacion cruzada, el error solo aparece al timbrar.

**Solución.** Derivar tipo de persona del largo del RFC normalizado: 13 chars = fisica, 12 = moral. Validar en zod (superRefine sobre el objeto artesano) que el regimen_fiscal elegido tenga persona_fisica/persona_moral compatible segun la tabla sat_regimen_fiscal (caso del primer item). Mensaje: 'El regimen 601 es solo para personas morales; este RFC es de persona fisica'. En el form, filtrar el SelectField de regimen segun el RFC ya capturado.

**Idempotencia/seguridad.** n/a (validacion).

### 126. 🟢 Baja
**Escenario.** El SelectField de artesano en producto-form (linea 74-83) lista artesanos por nombre incluyendo los que tienen status='pausado'. listarArtesanosOpciones (artesanos.ts linea 31) hace select sin filtrar por status.

**Problema.** El admin puede asignar una pieza publicada a un artesano pausado. La vista publica artesanos_publicos filtra status='activo', asi que la pieza publica mostraria un maker cuyo perfil de artesano no es visible publicamente: enlace roto / autor fantasma en el sitio.

**Solución.** En listarArtesanosOpciones, devolver tambien status y en el SelectField marcar los pausados ('Macrina Pacheco (pausado)') o agruparlos. En el server action, si status del producto='publicado' y el artesano asignado esta 'pausado', advertir o impedir. Decision de producto: permitir la asignacion pero avisar, ya que pausar un artesano podria deber despublicar sus piezas (regla a definir).

**Idempotencia/seguridad.** n/a.

### 127. 🟡 Media · **⚡ implementar ya**
**Escenario.** Datos legacy del seed.sql: artesanos y productos se insertaron con region='Edo. de Mexico', oficios con capitalizacion variable, regimen_fiscal/rfc/clabe en null. Cuando se introduzcan los catalogos (regimen, estados, oficios), estos registros existentes no cumpliran las nuevas FK.

**Problema.** Agregar FOREIGN KEY (region) REFERENCES estados_mx o (regimen_fiscal) REFERENCES sat_regimen_fiscal fallara la migracion por filas existentes que no matchean ('Edo. de Mexico' no esta como clave). La migracion abortara o dejara datos inconsistentes.

**Solución.** Migracion de datos legacy en orden estricto: 1) crear y seedear tablas catalogo. 2) UPDATE de normalizacion mapeando variantes legacy a valores canonicos (region, oficio) con un CASE/IN exhaustivo. 3) Verificar que no quedan valores fuera del catalogo: SELECT distinct region FROM artesanos WHERE region NOT IN (SELECT clave FROM estados_mx). 4) Solo entonces ALTER TABLE ADD CONSTRAINT ... FK. Para regimen_fiscal nullable, la FK con NULL permitido no rompe (NULL no se valida contra FK).

**Idempotencia/seguridad.** Cada UPDATE es idempotente (mapea variante->canonico; reejecutar no altera lo ya canonico). Crear constraint con IF NOT EXISTS / chequear pg_constraint para no fallar al reejecutar.

### 128. 🟢 Baja · **⚡ implementar ya**
**Escenario.** optText en schemas.ts hace trim y convierte '' en undefined->null, pero no colapsa espacios internos ni normaliza unicode/acentos. Un admin pega 'Oaxaca ' con espacio, o 'Oaxaca' con acento combinante vs precompuesto, o doble espacio en maker.

**Problema.** Aunque haya catalogo, los campos que siguen siendo libres (nombre, maker manual, semblanza, tecnica, materiales) acumulan variantes invisibles que rompen busqueda/orden. 'Macrina Pacheco' vs 'Macrina  Pacheco' (doble espacio) se ordenan/agrupan distinto en listarArtesanosOpciones (order by nombre).

**Solución.** Reforzar optText y los campos requeridos con normalizacion: .transform(v => v.normalize('NFC').replace(/\s+/g,' ').trim()). Aplicar a nombre, maker, oficio (si libre), region (si libre), tecnica, materiales, medidas. Es una sola utilidad zod reutilizable. No afecta el contenido visible pero garantiza claves estables para orden/busqueda/joins por nombre.

**Idempotencia/seguridad.** Normalizacion idempotente (NFC + colapso de espacios aplicado dos veces da el mismo resultado).

### 129. 🟡 Media
**Escenario.** El id de producto es el slug-PK escrito a mano por el admin ('tal-03', producto-form.tsx linea 51-58) y la PK no es editable. El admin reutiliza un prefijo agotado o escribe 'TAL-03' (mayusculas) o 'tal 03' (espacio) que el slug zod rechaza, pero no hay generador asistido por oficio.

**Problema.** La convencion de id (prefijo de oficio + numero: tal-/bar-/ale-/tel-/ces-) es implicita y fragil. Dos admins generan colisiones o ids incoherentes con el oficio. El UNIQUE de la PK solo da error crudo 'duplicate' despues de fallar. No hay pre-relleno sensato del id a partir del oficio/artesano seleccionado.

**Solución.** Pre-rellenar (sugerir) el id en el cliente al elegir oficio/artesano: derivar prefijo del oficio del catalogo (oficios.slug -> 3 letras) + siguiente correlativo. El server NO confia en eso: valida slug y, ante colision, en vez de fallar puede sugerir el siguiente disponible. Mantener id escribible (override) pero con default util. Documentar la convencion en hint. La autoridad sigue siendo el UNIQUE de la PK en BD.

**Idempotencia/seguridad.** El UNIQUE(id) en BD es el respaldo ante doble submit/concurrencia: dos inserts con el mismo id, el segundo falla (ya manejado como 'Ya existe una pieza con ese identificador').

### 130. 🔴 Alta · **⚡ implementar ya**
**Escenario.** Doble submit del form de crear artesano (admin hace doble click, o reintento por red lenta sobre Tailscale HTTP). crearArtesano inserta con toRow; el unico respaldo de unicidad es slug UNIQUE. Pero si el admin deja el slug ligeramente distinto ('macrina-pacheco' vs 'macrina-pacheco-1'), se crean dos artesanos casi-duplicados con el mismo RFC/CLABE.

**Problema.** Concurrencia/reintento crea artesanos duplicados que comparten datos fiscales (mismo RFC/CLABE), lo que en la fase de dispersion significaria pagar/retener dos veces o emitir CFDI duplicados al mismo contribuyente. El slug UNIQUE no protege porque el slug difiere.

**Solución.** Agregar el indice unico parcial sobre upper(rfc) (caso RFC) y sobre clabe: CREATE UNIQUE INDEX artesanos_clabe_uniq ON artesanos (clabe) WHERE clabe IS NOT NULL. Asi dos artesanos no pueden compartir RFC ni CLABE, cerrando el duplicado a nivel BD aunque el slug difiera. Para el doble-submit puro, aceptar un idempotency key opcional del form o deshabilitar el boton en pending (ya hay 'pending' en useActionState) y confiar en los UNIQUE como respaldo real.

**Idempotencia/seguridad.** Garantizada por UNIQUE en BD (no solo logica app), exactamente como exige la politica del proyecto: el segundo insert concurrente con mismo RFC/CLABE falla en Postgres.

### 131. 🟢 Baja
**Escenario.** regimen_fiscal, oficio y region en el form de artesano son opcionales y se pueden dejar vacios. El dashboard usa ventas simuladas y agrupa por region/oficio. Artesanos sin esos campos quedan fuera de toda agrupacion y, sin regimen_fiscal, no se les puede calcular la tasa de retencion futura.

**Problema.** Falta de valores por defecto sensatos y de completitud minima. Un artesano 'activo' sin oficio/region es invisible en filtros y, sin regimen, indeterminado fiscalmente. No hay indicador de 'perfil incompleto' que guie al admin.

**Solución.** No inventar defaults para datos fiscales (peligroso), pero si: 1) marcar oficio y region como requeridos una vez exista catalogo (son catalogables, bajo costo). 2) Mostrar en la lista de artesanos un badge 'perfil incompleto' (sin regimen/rfc/clabe) calculado en server. 3) Para status, el default 'activo' ya es sensato pero considerar default 'pausado' hasta que el perfil este completo, evitando publicar artesanos sin datos minimos. Decidir con el cliente.

**Idempotencia/seguridad.** n/a.

### 132. 🟢 Baja · **⚡ implementar ya**
**Escenario.** Los catalogos nuevos (sat_regimen_fiscal, estados_mx, oficios) necesitan RLS. La politica actual solo da CRUD a admin y SELECT a anon sobre productos publicados / artesanos_publicos. Si se crean tablas catalogo sin RLS habilitado, quedan accesibles por defecto o, si se habilita RLS sin policy, nadie las lee y los SelectField del form quedan vacios.

**Problema.** Olvidar la policy de los catalogos rompe los selects (form sin opciones) o expone/oculta de mas. estados_mx y sat_regimen_fiscal son catalogos publicos no sensibles; oficios tambien. Pero la ESCRITURA de oficios (agregar oficio nuevo) debe ser solo admin.

**Solución.** Para cada catalogo: alter table ... enable row level security; create policy ..._select on <cat> for select to anon, authenticated using (true); y para oficios, ademas create policy oficios_admin_write on oficios for all to authenticated using (is_admin()) with check (is_admin()). sat_regimen_fiscal y estados_mx son de solo lectura para todos y se modifican via migracion (sin policy de write, RLS deniega escritura por sesion). Asi los SelectField del admin y del sitio publico leen el catalogo, y solo el admin extiende oficios.

**Idempotencia/seguridad.** drop policy if exists antes de create (como ya hace 0001_init.sql) para reejecutar la migracion sin fallar.
