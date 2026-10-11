# Sistema para telas (nombre por definir)

Plataforma multiempresa, multisucursal y multialmacén para importación, distribución y venta de telas por rollos y cortes, con trazabilidad por pieza y etiqueta QR.

## Estado

| Fase | Estado |
| --- | --- |
| 1 · Análisis y definición | Cerrada (17 decisiones aprobadas) |
| 2 · Arquitectura técnica (base de datos) | Hecha: 72 pruebas superadas en local y base desplegada en Supabase |
| 3 · Diseño de pantallas | Pendiente |

## Estructura

- [`db/`](db/README.md): migraciones PostgreSQL (tablas, seguridad por fila, funciones de recepción), pruebas y herramientas locales.

Tecnología decidida: PostgreSQL + TypeScript, aplicación web instalable (PWA) en Supabase + Vercel.
