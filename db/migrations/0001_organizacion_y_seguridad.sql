-- =====================================================================
-- 0001 · Organización y seguridad
-- Plataforma → Empresa → Sucursal → Almacén → Ubicación
-- Usuarios, roles, permisos y membresías (usuario + empresa + rol + alcance)
-- Decisiones: D-01, D-08, P-03, P-11 (ver documento de definición)
-- =====================================================================

create extension if not exists pgcrypto;

-- Esquema privado para funciones auxiliares que no se exponen por la API.
create schema if not exists privado;

-- ---------------------------------------------------------------------
-- Perfil de usuario (1 a 1 con auth.users de Supabase)
-- ---------------------------------------------------------------------
create table public.perfil_usuario (
  id                    uuid primary key references auth.users (id),
  nombre                text not null check (length(trim(nombre)) > 0),
  es_admin_plataforma   boolean not null default false,
  activo                boolean not null default true,
  creado_en             timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Empresa: raíz del aislamiento
-- ---------------------------------------------------------------------
create table public.empresa (
  id              uuid primary key default gen_random_uuid(),
  nombre          text not null check (length(trim(nombre)) > 0),
  ident_fiscal    text,
  -- P-03: sin prefijo por defecto; disponible si algún día se necesita.
  prefijo_codigo  text check (prefijo_codigo ~ '^[A-Z0-9]{1,4}$'),
  usar_prefijo    boolean not null default false,
  activo          boolean not null default true,
  creado_en       timestamptz not null default now(),
  check (not usar_prefijo or prefijo_codigo is not null)
);

-- ---------------------------------------------------------------------
-- Sucursal, almacén, ubicación
-- Las claves foráneas compuestas (empresa_id, id) impiden por construcción
-- que un registro de la empresa A apunte a otro de la empresa B.
-- ---------------------------------------------------------------------
create table public.sucursal (
  id            uuid primary key default gen_random_uuid(),
  empresa_id    uuid not null references public.empresa (id),
  codigo        text not null check (codigo ~ '^[A-Z0-9_-]{1,20}$'),
  nombre        text not null,
  ciudad        text,
  region        text,           -- estado o provincia
  activo        boolean not null default true,
  creado_en     timestamptz not null default now(),
  unique (empresa_id, codigo),
  unique (empresa_id, id)
);

create table public.almacen (
  id            uuid primary key default gen_random_uuid(),
  empresa_id    uuid not null,
  sucursal_id   uuid not null,
  codigo        text not null check (codigo ~ '^[A-Z0-9_-]{1,20}$'),
  nombre        text not null,
  activo        boolean not null default true,
  creado_en     timestamptz not null default now(),
  foreign key (empresa_id, sucursal_id) references public.sucursal (empresa_id, id),
  unique (empresa_id, codigo),
  unique (empresa_id, id),
  unique (empresa_id, sucursal_id, id)
);

create table public.ubicacion (
  id            uuid primary key default gen_random_uuid(),
  empresa_id    uuid not null,
  almacen_id    uuid not null,
  codigo        text not null,          -- zona-pasillo-estante, o "GENERAL"
  descripcion   text,
  activo        boolean not null default true,
  creado_en     timestamptz not null default now(),
  foreign key (empresa_id, almacen_id) references public.almacen (empresa_id, id),
  unique (empresa_id, almacen_id, codigo),
  unique (empresa_id, id),
  unique (empresa_id, almacen_id, id)
);

-- ---------------------------------------------------------------------
-- Permisos (catálogo global), roles por empresa y membresías
-- ---------------------------------------------------------------------
create table public.permiso (
  codigo        text primary key check (codigo ~ '^[a-z_]+\.[a-z_]+$'),
  descripcion   text not null,
  sensible      boolean not null default false
);

create table public.rol (
  id            uuid primary key default gen_random_uuid(),
  empresa_id    uuid not null references public.empresa (id),
  nombre        text not null,
  descripcion   text,
  activo        boolean not null default true,
  unique (empresa_id, nombre),
  unique (empresa_id, id)
);

create table public.rol_permiso (
  empresa_id      uuid not null,
  rol_id          uuid not null,
  permiso_codigo  text not null references public.permiso (codigo),
  primary key (rol_id, permiso_codigo),
  foreign key (empresa_id, rol_id) references public.rol (empresa_id, id)
);

create table public.membresia (
  id                  uuid primary key default gen_random_uuid(),
  empresa_id          uuid not null references public.empresa (id),
  usuario_id          uuid not null references public.perfil_usuario (id),
  rol_id              uuid not null,
  todas_sucursales    boolean not null default false,
  activo              boolean not null default true,
  creado_en           timestamptz not null default now(),
  foreign key (empresa_id, rol_id) references public.rol (empresa_id, id),
  unique (empresa_id, usuario_id, rol_id),
  unique (empresa_id, id)
);

-- Alcance: si la membresía no es de todas las sucursales, solo vale en estas.
create table public.membresia_sucursal (
  empresa_id      uuid not null,
  membresia_id    uuid not null,
  sucursal_id     uuid not null,
  primary key (membresia_id, sucursal_id),
  foreign key (empresa_id, membresia_id) references public.membresia (empresa_id, id),
  foreign key (empresa_id, sucursal_id) references public.sucursal (empresa_id, id)
);

create index on public.membresia (usuario_id) where activo;

-- ---------------------------------------------------------------------
-- Catálogo de permisos
-- ---------------------------------------------------------------------
insert into public.permiso (codigo, descripcion, sensible) values
  ('config.ver',               'Consultar sucursales, almacenes, usuarios y roles', false),
  ('config.editar',            'Crear y editar sucursales, almacenes, ubicaciones, roles y membresías', true),
  ('catalogo.ver',             'Consultar artículos y proveedores', false),
  ('catalogo.editar',          'Crear y editar artículos y proveedores', false),
  ('recepcion.ver',            'Consultar recepciones, cuadres y piezas', false),
  ('recepcion.crear',          'Abrir recepciones y cargar líneas esperadas', false),
  ('recepcion.registrar_pieza','Registrar piezas con su peso o metraje', false),
  ('recepcion.verificar',      'Cerrar el registro y enviar la recepción al gerente', false),
  ('recepcion.aprobar',        'Aprobar o rechazar recepciones a la vista del cuadre', true),
  ('recepcion.anular',         'Anular recepciones o piezas con motivo', true),
  ('pieza.liberar',            'Liberar piezas de cuarentena al inventario comercial', true),
  ('pieza.resolver_incidencia','Resolver incidencias de piezas', true),
  ('etiqueta.imprimir',        'Imprimir y reimprimir etiquetas', false),
  ('auditoria.ver',            'Consultar la auditoría', false);
