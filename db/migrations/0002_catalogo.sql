-- =====================================================================
-- 0002 · Catálogo: unidades, artículos y proveedores
-- Decisiones: P-07 (abreviatura manual, única, bloqueada tras el primer uso)
-- =====================================================================

-- Unidades globales. Cada artículo elige la suya: no se impone una única unidad.
create table public.unidad_medida (
  codigo    text primary key,
  nombre    text not null,
  magnitud  text not null check (magnitud in ('peso', 'longitud'))
);

insert into public.unidad_medida (codigo, nombre, magnitud) values
  ('kg', 'Kilogramo', 'peso'),
  ('m',  'Metro',     'longitud'),
  ('yd', 'Yarda',     'longitud');

create table public.articulo (
  id                      uuid primary key default gen_random_uuid(),
  empresa_id              uuid not null references public.empresa (id),
  codigo                  text not null check (codigo ~ '^[A-Z0-9_-]{2,20}$'),   -- MUTJ001
  descripcion             text not null check (length(trim(descripcion)) > 0),
  material                text,
  color                   text,
  abreviatura             text not null check (abreviatura ~ '^[A-Z0-9]{2,6}$'),  -- MUB
  abreviatura_bloqueada   boolean not null default false,
  unidad_control          text not null references public.unidad_medida (codigo),
  unidad_venta            text references public.unidad_medida (codigo),
  -- Tope de sensatez para detectar errores de tecleo (p. ej. 1250 en vez de 12,50).
  cantidad_max_pieza      numeric(12,2) check (cantidad_max_pieza > 0),
  activo                  boolean not null default true,
  creado_en               timestamptz not null default now(),
  unique (empresa_id, codigo),
  unique (empresa_id, abreviatura),
  unique (empresa_id, id)
);

-- Conversiones solo cuando están definidas para ese artículo.
create table public.conversion_unidad (
  empresa_id    uuid not null,
  articulo_id   uuid not null,
  desde         text not null references public.unidad_medida (codigo),
  hasta         text not null references public.unidad_medida (codigo),
  factor        numeric(14,6) not null check (factor > 0),
  primary key (articulo_id, desde, hasta),
  foreign key (empresa_id, articulo_id) references public.articulo (empresa_id, id),
  check (desde <> hasta)
);

create table public.proveedor (
  id            uuid primary key default gen_random_uuid(),
  empresa_id    uuid not null references public.empresa (id),
  codigo        text not null check (codigo ~ '^[A-Z0-9_-]{1,20}$'),
  nombre        text not null check (length(trim(nombre)) > 0),
  ident_fiscal  text,
  pais          text,
  contacto      text,
  activo        boolean not null default true,
  creado_en     timestamptz not null default now(),
  unique (empresa_id, codigo),
  unique (empresa_id, id)
);

-- P-07: una vez usada para emitir piezas, la abreviatura no puede cambiar.
create function privado.proteger_abreviatura() returns trigger
language plpgsql as $$
begin
  if old.abreviatura_bloqueada and new.abreviatura <> old.abreviatura then
    raise exception 'La abreviatura % ya se usó en piezas emitidas y no puede cambiarse', old.abreviatura
      using errcode = 'check_violation';
  end if;
  if old.abreviatura_bloqueada and not new.abreviatura_bloqueada then
    raise exception 'No se puede desbloquear una abreviatura ya usada' using errcode = 'check_violation';
  end if;
  if new.unidad_control <> old.unidad_control and old.abreviatura_bloqueada then
    raise exception 'No se puede cambiar la unidad de control de un artículo con piezas emitidas'
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

create trigger articulo_proteger_abreviatura
  before update on public.articulo
  for each row execute function privado.proteger_abreviatura();
