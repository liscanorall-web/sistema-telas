-- =====================================================================
-- 0003 · Recepción, piezas, eventos, cuadre y auditoría
-- Decisiones: D-03, D-04, D-06, D-07, P-04, P-05, P-06, P-08, P-09, P-13
-- =====================================================================

-- P-13: estados separados para el documento y para cada pieza.
create type public.estado_recepcion as enum (
  'en_preparacion',          -- se cargan líneas y se registran piezas
  'pendiente_verificacion',  -- registro cerrado, falta el control físico y documental
  'pendiente_autorizacion',  -- P-09: siempre pasa por el gerente con el cuadre
  'verificada',              -- aprobada por el gerente; piezas listas para liberar
  'cerrada',                 -- todas sus piezas liberadas, rechazadas o anuladas
  'rechazada',
  'anulada'
);

create type public.estado_pieza as enum (
  'en_cuarentena',
  'pendiente_autorizacion',  -- tiene una incidencia abierta
  'liberada',                -- única condición para estar disponible (D-06)
  'rechazada',
  'anulada'
  -- Futuro (fase 9): reservada, en_picking, en_transito, despachada, salida_definitiva
);

-- ---------------------------------------------------------------------
-- Recepción
-- ---------------------------------------------------------------------
create table public.contador_recepcion (
  empresa_id  uuid primary key references public.empresa (id),
  ultimo      bigint not null default 0
);

create table public.recepcion (
  id                  uuid primary key default gen_random_uuid(),
  empresa_id          uuid not null references public.empresa (id),
  numero              text not null,                      -- REC-000001
  proveedor_id        uuid not null,
  documento_tipo      text not null check (documento_tipo in ('factura', 'orden_compra', 'lista_empaque', 'otro')),
  documento_numero    text not null check (length(trim(documento_numero)) > 0),
  fecha_recepcion     date not null,                      -- P-04: da la fecha al código de pieza
  sucursal_id         uuid not null,
  almacen_id          uuid not null,
  estado              public.estado_recepcion not null default 'en_preparacion',
  observaciones       text,
  responsable_id      uuid not null references public.perfil_usuario (id),
  verificado_por      uuid references public.perfil_usuario (id),
  verificado_en       timestamptz,
  version             integer not null default 1,         -- control de concurrencia optimista
  creado_en           timestamptz not null default now(),
  unique (empresa_id, numero),
  unique (empresa_id, id),
  foreign key (empresa_id, proveedor_id) references public.proveedor (empresa_id, id),
  -- el almacén debe pertenecer a la sucursal indicada
  foreign key (empresa_id, sucursal_id, almacen_id) references public.almacen (empresa_id, sucursal_id, id)
);

create table public.recepcion_linea (
  id                  uuid primary key default gen_random_uuid(),
  empresa_id          uuid not null,
  recepcion_id        uuid not null,
  articulo_id         uuid not null,
  cantidad_esperada   numeric(12,2) check (cantidad_esperada > 0),   -- null = artículo no esperado
  piezas_esperadas    integer check (piezas_esperadas > 0),
  creado_en           timestamptz not null default now(),
  foreign key (empresa_id, recepcion_id) references public.recepcion (empresa_id, id),
  foreign key (empresa_id, articulo_id) references public.articulo (empresa_id, id),
  unique (recepcion_id, articulo_id),
  unique (empresa_id, id),
  unique (empresa_id, recepcion_id, id)
);

-- ---------------------------------------------------------------------
-- Pieza: la unidad central del sistema
-- ---------------------------------------------------------------------
create table public.contador_pieza (
  empresa_id    uuid not null references public.empresa (id),
  fecha         date not null,
  abreviatura   text not null,
  ultimo        integer not null default 0,
  primary key (empresa_id, fecha, abreviatura)
);

create table public.pieza (
  id                          uuid primary key default gen_random_uuid(),
  empresa_id                  uuid not null,
  codigo                      text not null,              -- 20261011-MUB-001 (D-04)
  fecha_codigo                date not null,
  abreviatura                 text not null,
  correlativo                 integer not null check (correlativo > 0),
  articulo_id                 uuid not null,
  recepcion_id                uuid not null,
  linea_id                    uuid not null,
  unidad                      text not null references public.unidad_medida (codigo),
  -- P-08: peso neto (o metraje) verificado, 2 decimales. Nunca cambia.
  cantidad_inicial            numeric(12,2) not null check (cantidad_inicial > 0),
  -- Solo cambia mediante eventos (ajuste autorizado, corte futuro: P-15).
  cantidad_actual             numeric(12,2) not null check (cantidad_actual >= 0),
  peso_etiqueta_fabricante    numeric(12,2) check (peso_etiqueta_fabricante > 0),
  estado                      public.estado_pieza not null default 'en_cuarentena',
  almacen_id                  uuid not null,
  ubicacion_id                uuid,
  clave_idempotencia          uuid not null,              -- evita duplicados por reintentos de red
  creado_por                  uuid not null references public.perfil_usuario (id),
  creado_en                   timestamptz not null default now(),
  -- La base de datos garantiza la unicidad, no la pantalla (D-04).
  unique (empresa_id, codigo),
  unique (empresa_id, fecha_codigo, abreviatura, correlativo),
  unique (empresa_id, clave_idempotencia),
  unique (empresa_id, id),
  foreign key (empresa_id, recepcion_id, linea_id) references public.recepcion_linea (empresa_id, recepcion_id, id),
  foreign key (empresa_id, articulo_id) references public.articulo (empresa_id, id),
  foreign key (empresa_id, almacen_id) references public.almacen (empresa_id, id),
  foreign key (empresa_id, almacen_id, ubicacion_id) references public.ubicacion (empresa_id, almacen_id, id)
);

create index on public.pieza (empresa_id, estado);
create index on public.pieza (recepcion_id);

-- Eventos de pieza: historia completa, solo inserción (D-07).
create table public.evento_pieza (
  id                bigint generated always as identity primary key,
  empresa_id        uuid not null,
  pieza_id          uuid not null,
  tipo              text not null check (tipo in (
                      'registrada', 'anulada', 'incidencia', 'incidencia_resuelta',
                      'aprobada_en_recepcion', 'rechazada', 'liberada',
                      'etiqueta_impresa', 'ajuste', 'traslado')),
  estado_anterior   public.estado_pieza,
  estado_nuevo      public.estado_pieza,
  datos             jsonb not null default '{}'::jsonb,
  motivo            text,
  usuario_id        uuid not null references public.perfil_usuario (id),
  creado_en         timestamptz not null default now(),
  foreign key (empresa_id, pieza_id) references public.pieza (empresa_id, id)
);

create index on public.evento_pieza (pieza_id, id);

create table public.incidencia (
  id              uuid primary key default gen_random_uuid(),
  empresa_id      uuid not null,
  recepcion_id    uuid not null,
  pieza_id        uuid,
  tipo            text not null check (tipo in ('danio', 'articulo_no_esperado', 'documental', 'otro')),
  descripcion     text not null check (length(trim(descripcion)) > 0),
  abierta         boolean not null default true,
  resolucion      text,
  creado_por      uuid not null references public.perfil_usuario (id),
  resuelto_por    uuid references public.perfil_usuario (id),
  creado_en       timestamptz not null default now(),
  resuelto_en     timestamptz,
  foreign key (empresa_id, recepcion_id) references public.recepcion (empresa_id, id),
  foreign key (empresa_id, pieza_id) references public.pieza (empresa_id, id)
);

-- Decisión del gerente sobre el cuadre (P-09), con la foto del cuadre que vio.
create table public.aprobacion_recepcion (
  id              uuid primary key default gen_random_uuid(),
  empresa_id      uuid not null,
  recepcion_id    uuid not null,
  decision        text not null check (decision in ('aprobada', 'rechazada')),
  motivo          text,
  cuadre          jsonb not null,
  aprobado_por    uuid not null references public.perfil_usuario (id),
  creado_en       timestamptz not null default now(),
  foreign key (empresa_id, recepcion_id) references public.recepcion (empresa_id, id)
);

create table public.etiqueta_impresion (
  id                  bigint generated always as identity primary key,
  empresa_id          uuid not null,
  pieza_id            uuid not null,
  numero_impresion    integer not null check (numero_impresion > 0),   -- 1 = original, 2+ = reimpresión
  plantilla_version   text not null default 'v1-100x150',
  usuario_id          uuid not null references public.perfil_usuario (id),
  creado_en           timestamptz not null default now(),
  foreign key (empresa_id, pieza_id) references public.pieza (empresa_id, id),
  unique (pieza_id, numero_impresion)
);

-- ---------------------------------------------------------------------
-- Auditoría genérica: quién, cuándo, antes y después. Solo inserción.
-- ---------------------------------------------------------------------
create table public.auditoria (
  id            bigint generated always as identity primary key,
  empresa_id    uuid,
  tabla         text not null,
  registro_id   text,
  accion        text not null check (accion in ('INSERT', 'UPDATE', 'DELETE')),
  antes         jsonb,
  despues       jsonb,
  usuario_id    uuid,
  creado_en     timestamptz not null default now()
);

create index on public.auditoria (empresa_id, creado_en desc);

create function privado.auditar() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  fila jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
begin
  insert into public.auditoria (empresa_id, tabla, registro_id, accion, antes, despues, usuario_id)
  values (
    case when tg_table_name = 'empresa' then (fila ->> 'id')::uuid else (fila ->> 'empresa_id')::uuid end,
    tg_table_name,
    coalesce(fila ->> 'id', fila ->> 'rol_id', fila ->> 'membresia_id'),
    tg_op,
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end,
    auth.uid()
  );
  return null;
end $$;

do $$
declare t text;
begin
  foreach t in array array[
    'empresa', 'sucursal', 'almacen', 'ubicacion', 'rol', 'rol_permiso', 'membresia',
    'membresia_sucursal', 'articulo', 'conversion_unidad', 'proveedor', 'recepcion',
    'recepcion_linea', 'pieza', 'incidencia']
  loop
    execute format('create trigger %I after insert or update or delete on public.%I
                    for each row execute function privado.auditar()', t || '_auditoria', t);
  end loop;
end $$;

-- Registros históricos: ni se editan ni se borran, por nadie (D-07).
create function privado.solo_insercion() returns trigger
language plpgsql as $$
begin
  raise exception 'La tabla % es histórica: no admite % (los errores se corrigen con un registro nuevo)',
    tg_table_name, tg_op using errcode = 'insufficient_privilege';
end $$;

do $$
declare t text;
begin
  foreach t in array array['evento_pieza', 'aprobacion_recepcion', 'etiqueta_impresion', 'auditoria']
  loop
    execute format('create trigger %I before update or delete on public.%I
                    for each row execute function privado.solo_insercion()', t || '_solo_insercion', t);
  end loop;
end $$;

-- Piezas y recepciones nunca se borran: se anulan.
create function privado.prohibir_borrado() returns trigger
language plpgsql as $$
begin
  raise exception 'Los registros de % no se borran; se anulan con motivo', tg_table_name
    using errcode = 'insufficient_privilege';
end $$;

create trigger pieza_sin_borrado before delete on public.pieza
  for each row execute function privado.prohibir_borrado();
create trigger recepcion_sin_borrado before delete on public.recepcion
  for each row execute function privado.prohibir_borrado();
create trigger recepcion_linea_sin_borrado before delete on public.recepcion_linea
  for each row execute function privado.prohibir_borrado();

-- La identidad y el peso inicial de una pieza son inmutables (D-04, D-07).
create function privado.proteger_pieza() returns trigger
language plpgsql as $$
begin
  if new.codigo <> old.codigo or new.fecha_codigo <> old.fecha_codigo
     or new.abreviatura <> old.abreviatura or new.correlativo <> old.correlativo
     or new.articulo_id <> old.articulo_id or new.recepcion_id <> old.recepcion_id
     or new.cantidad_inicial <> old.cantidad_inicial or new.empresa_id <> old.empresa_id then
    raise exception 'La identidad y el peso inicial de la pieza % no pueden modificarse', old.codigo
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

create trigger pieza_proteger before update on public.pieza
  for each row execute function privado.proteger_pieza();
