-- =====================================================================
-- 0006 · Ajustes tras el análisis de seguridad de Supabase (11/10/2026)
-- =====================================================================

-- Funciones de disparador con search_path fijo (aviso 0011 del linter).
alter function privado.proteger_abreviatura() set search_path = pg_catalog, public;
alter function privado.solo_insercion()       set search_path = pg_catalog, public;
alter function privado.prohibir_borrado()     set search_path = pg_catalog, public;
alter function privado.proteger_pieza()       set search_path = pg_catalog, public;

-- La vista del cuadre nunca es accesible sin sesión.
revoke all on public.vista_cuadre_recepcion from anon, public;

-- Contadores: RLS activa y sin políticas a propósito. Nadie los lee ni los
-- escribe desde la API; solo las funciones de recepción los incrementan.
comment on table public.contador_pieza is
  'Correlativo por empresa + fecha + abreviatura. Sin acceso desde la API (RLS sin políticas, intencionado).';
comment on table public.contador_recepcion is
  'Número de recepción por empresa. Sin acceso desde la API (RLS sin políticas, intencionado).';

-- Las funciones públicas SECURITY DEFINER son la puerta intencionada para
-- cambiar recepciones y piezas: cada una comprueba sesión, permiso, empresa,
-- sucursal y estado antes de actuar (aviso 0029 del linter, aceptado).
