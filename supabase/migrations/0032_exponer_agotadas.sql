-- 0032 — Exponer piezas AGOTADAS en el storefront (mostrarlas como "Vendida", no 404)
-- El trigger derivar_status_agotado marca status='agotado' al llegar a 0 stock, y las policies
-- de anon solo exponían 'publicado' → una pieza VENDIDA desaparecía (404 en link directo) y el
-- badge "Agotado/Vendida" quedaba inalcanzable. Ampliamos a ('publicado','agotado') las 4 policies
-- de lectura pública (productos + variantes/imágenes/inventario). Los borradores siguen ocultos.
-- ALTER POLICY solo cambia el USING (conserva rol y comando).

alter policy productos_publicados_select on public.productos
  using (status in ('publicado', 'agotado'));

alter policy producto_variantes_public_select on public.producto_variantes
  using (
    exists (
      select 1 from public.productos p
      where p.id = producto_variantes.producto_id and p.status in ('publicado', 'agotado')
    )
  );

alter policy producto_imagenes_public_select on public.producto_imagenes
  using (
    exists (
      select 1 from public.productos p
      where p.id = producto_imagenes.producto_id and p.status in ('publicado', 'agotado')
    )
  );

alter policy inventario_public_select on public.inventario
  using (
    exists (
      select 1
      from public.producto_variantes pv
      join public.productos p on p.id = pv.producto_id
      where pv.id = inventario.variante_id and p.status in ('publicado', 'agotado')
    )
  );
