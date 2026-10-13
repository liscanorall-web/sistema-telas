# Base de datos · Sistema para telas (nombre por definir)

Fase 2 (arquitectura técnica). PostgreSQL con seguridad por fila (RLS), pensado para Supabase (decisiones P-01 y P-02).
La definición funcional y el registro de decisiones están en el documento de definición del proyecto.

## Contenido

| Archivo | Qué hace |
| --- | --- |
| `migrations/0001_organizacion_y_seguridad.sql` | Empresas, sucursales, almacenes, ubicaciones, usuarios, roles, permisos y membresías |
| `migrations/0002_catalogo.sql` | Unidades, artículos (abreviatura única y bloqueable), conversiones, proveedores |
| `migrations/0003_recepcion_y_piezas.sql` | Recepciones, líneas, piezas, eventos, incidencias, aprobaciones, etiquetas, auditoría e inmutabilidad |
| `migrations/0004_aislamiento_y_permisos.sql` | Políticas RLS por empresa y sucursal; privilegios de la API |
| `migrations/0005_operaciones_de_recepcion.sql` | Funciones que usa la aplicación: abrir recepción, registrar pieza, cuadre, aprobar, liberar, QR |
| `migrations/0006_ajustes_de_seguridad.sql` | Ajustes tras el análisis de seguridad de Supabase (search_path fijo, vista sin acceso anónimo) |
| `migrations/0007_articulo_por_color.sql` | Catálogo por tela y color: cada color es un artículo; misma unidad para todos los colores de una tela; QR con «Metraje» en telas por metro |
| `tests/pruebas_fase2.sql` | 77 pruebas de aceptación (aislamiento, catálogo, permisos, identificadores, historial, flujo, etiqueta) |
| `tests/concurrencia.sh` | 4 operarios registrando 100 piezas a la vez en la misma línea |
| `local/00_supabase_stub.sql` | Solo local: imita `auth.uid()` y los roles de Supabase. No se aplica en Supabase |
| `local/aplicar_local.sh` | Recrea la base local y aplica stub + migraciones |

## Probar en local

```bash
bash local/aplicar_local.sh                       # base "telas" desde cero
su postgres -c "psql -d telas -f tests/pruebas_fase2.sql"
bash tests/concurrencia.sh
```

## Aplicar en Supabase

Aplicar `migrations/*.sql` en orden (por ejemplo con `supabase db push` o el editor SQL). No aplicar `local/`.
Proyecto actual: «sistema-telas» (`vkupqyetqvlolsurshfa`, São Paulo), con las migraciones 0001 a 0006 aplicadas y verificadas el 11/10/2026.
La API debe exponer solo el esquema `public`; el esquema `privado` contiene las funciones auxiliares de permisos.

## Reglas que garantiza la base de datos (no la pantalla)

- Cada usuario solo lee y escribe filas de las empresas y sucursales de sus membresías (RLS).
- Las relaciones llevan `empresa_id` en la clave foránea: un registro de una empresa no puede apuntar a otra.
- Recepciones y piezas solo cambian mediante funciones que comprueban permiso, sucursal y estado.
- Cada color de una tela es un artículo con código y abreviatura propios; todos los colores de una tela usan la misma unidad (kg o m).
- Código de pieza `AAAAMMDD-ABR-NNN` único por empresa; correlativo con bloqueo de fila; nunca se reutiliza.
- Peso inicial e identidad de la pieza inmutables; piezas y recepciones no se borran, se anulan.
- Eventos, aprobaciones, impresiones y auditoría son de solo inserción.
- Doble control: quien envía a aprobación no aprueba; quien registra una incidencia no la resuelve.
- Toda recepción pasa por el gerente con el cuadre; liberar es una acción explícita aparte.
