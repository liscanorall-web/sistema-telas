# Avance de la Fase 3 (diseño)

Corte del 12/10/2026. Prototipo navegable: https://claude.ai/artifact/KwMXpXgQvGqmaiFBW7pwtT (versión 18). Su fuente es `prototipo-recepcion.html` en esta carpeta.

Los datos que se cargan en el prototipo se guardan solo en el navegador de quien lo usa. No están en la base de datos real.

## Flujo acordado

1. **Artículos**: se crean antes de comprar. Hay tres niveles: línea (Microfibra), categoría (Unicolor, Estampado) y artículo (cada color o diseño, con su código y abreviatura).
   - El código y la abreviatura se proponen solos y nunca se repiten.
   - La unidad (kilo o metro), el ancho y el tope van por categoría.
   - Línea, categoría y nombre del color o diseño se pueden editar. El código y la abreviatura no cambian nunca, y cada cambio queda anotado.
   - Un solo botón, **Nuevo artículo**: si la línea y la categoría ya existen, los nuevos colores o diseños se suman a ella con su unidad, ancho y tope.
   - Cada color o diseño muestra código, nombre y **existencia** (lo disponible en anaqueles, más lo que está por ubicar). Con un clic se ven los anaqueles donde está. La abreviatura, la unidad y el tope no se muestran en la lista (se siguen usando y se ven en Editar).
   - Búsqueda rápida, tecleando o con escáner: por código, abreviatura, línea, categoría, color o diseño. Al escanear la etiqueta de un rollo muestra su artículo, su estado y su anaquel.
2. **Proveedores**.
3. **Ubicaciones**:
   - Muelles de recepción.
   - Pasillo, luego rack, luego anaquel (cada división del rack), con código P01-R01-A01.
   - Un rack se crea con todas sus divisiones de una vez.
   - Hay etiquetas QR para anaqueles y muelles, que se imprimen por ubicación, por rack o por pasillo.
4. **Compras**: el gerente general registra la orden de compra con lo pedido.
5. **Recepción**: el gerente de recepción la abre desde la orden de compra (trae lo pendiente).
   - Corrige según la factura, anota el número de contenedor y elige el muelle.
   - Los rollos se registran de corrido en el muelle y las etiquetas se imprimen en lote.
   - Después vienen la verificación, la aprobación del gerente general con el cuadre (pedido, facturado y recibido) y la liberación.
   - Al final, el **traslado** a anaqueles por escaneo: primero el anaquel, luego cada rollo. Solo entonces el rollo queda disponible para la venta.
   - La recepción se cierra con el último traslado.
   - Se guardan los **tiempos** de cada etapa y el total.
6. **Existencias** (para ventas): lo disponible por artículo o por anaquel, con rollos, cantidad (kilos y metros por separado) y anaqueles. Lo que sigue en muelle o cuarentena aparece aparte como "por ubicar". Se busca tecleando o escaneando un rollo o un anaquel.
7. **Ajustes de inventario**: ajuste de entrada (sumar a un rollo o crear un rollo nuevo con su código y etiqueta) y de salida (restar; un rollo en cero queda agotado). Cada uno lleva número (AJE-000001, AJS-000001), motivo de una lista que amplía el administrador y aprobación de un gerente distinto de quien lo registró. Las existencias cambian solo al aprobar; un rechazo lleva motivo.
8. **Traslados entre almacenes** (Almacén principal y Piso de ventas): se escanean los rollos (TRA-000001); al aprobarlo otro gerente salen "en tránsito" y quedan disponibles solo cuando el destino los escanea en su anaquel. Se guardan los tiempos (registrado, salió, recibido). Los anaqueles del piso de ventas llevan prefijo PV- (PV-P01-R01-A01); Ubicaciones y Existencias se filtran por almacén.

Mapa de módulos y decisiones (13/10/2026): https://claude.ai/code/artifact/0db53b74-4b8b-43e5-b6fb-65f008b1dd54 . 10 módulos (con Contabilidad en este sistema); registros en bolívares, todo visible también en dólares a la tasa BCV del día.

Pasillos, racks, líneas y categorías se muestran plegados. Lo que cada persona despliega se recuerda en su navegador.

## Pendiente

- **Decisión de Richard**: el tiempo de la recepción, ¿cuenta desde que llega el contenedor (recomendado) o desde que se abre en el sistema?
- **Base de datos**: pasar a la base lo validado. Eso incluye línea y categoría (ajustando la migración 0007), compras, muelles, pasillo/rack/anaquel, traslado, estado "disponible" y tiempos.
- **PR #1**: lo fusiona Richard. Después se aplica la migración en Supabase.
- **Ideas propuestas**:
  - etiqueta de anaquel más chica, si hace falta.
