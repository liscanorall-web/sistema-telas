-- =====================================================================
-- 0007 · Catálogo por tela y color (decisión del 11/10/2026)
-- Cada color de una tela es un artículo con su propio código y su abreviatura.
-- Todos los colores de una tela se controlan por la misma unidad (kilo o metro).
-- La etiqueta dice "Peso neto" en telas por peso y "Metraje" en telas por longitud.
-- =====================================================================

-- "material" ya guardaba el nombre de la tela; pasa a llamarse así.
alter table public.articulo rename column material to tela;

-- Artículos previos sin tela o sin color (no debería haber): se completan antes de exigirlos.
update public.articulo
   set tela  = coalesce(nullif(trim(tela), ''), descripcion),
       color = coalesce(nullif(trim(color), ''), 'Sin color')
 where tela is null or trim(tela) = '' or color is null or trim(color) = '';

alter table public.articulo
  alter column tela set not null,
  alter column color set not null,
  add constraint articulo_tela_no_vacia check (length(trim(tela)) > 0),
  add constraint articulo_color_no_vacio check (length(trim(color)) > 0),
  add column composicion text,
  add column ancho_cm numeric(6,2) check (ancho_cm > 0);

-- Un mismo color no se repite dentro de una tela (sin distinguir mayúsculas).
create unique index articulo_tela_color_unico
  on public.articulo (empresa_id, lower(trim(tela)), lower(trim(color)));
create index articulo_tela on public.articulo (empresa_id, lower(trim(tela)));

-- Todos los colores de una tela comparten unidad de control.
create function privado.validar_unidad_de_tela() returns trigger
language plpgsql set search_path = pg_catalog, public as $$
declare v_otra text;
begin
  select a.unidad_control into v_otra
    from public.articulo a
   where a.empresa_id = new.empresa_id
     and lower(trim(a.tela)) = lower(trim(new.tela))
     and a.id <> new.id
     and a.unidad_control <> new.unidad_control
   limit 1;
  if v_otra is not null then
    raise exception 'Todos los colores de % se controlan por la misma unidad (%)', new.tela, v_otra
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

create trigger articulo_unidad_de_tela
  before insert or update of tela, unidad_control on public.articulo
  for each row execute function privado.validar_unidad_de_tela();

revoke execute on function privado.validar_unidad_de_tela() from public, anon;

-- La cédula del QR nombra el dato según la unidad: peso neto o metraje.
create or replace function public.contenido_qr(p_pieza uuid) returns text
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare r record;
begin
  select p.*, a.codigo as art_codigo, a.descripcion as art_descripcion, u.magnitud
    into r
    from public.pieza p
    join public.articulo a on a.id = p.articulo_id
    join public.unidad_medida u on u.codigo = p.unidad
   where p.id = p_pieza;
  if not found then raise exception 'La pieza no existe' using errcode = '23503'; end if;
  perform privado.exigir_permiso(r.empresa_id, 'recepcion.ver', privado.sucursal_de_almacen(r.almacen_id));
  return r.codigo || E'\n'
      || r.art_codigo || ' ' || r.art_descripcion || E'\n'
      || case when r.magnitud = 'peso' then 'Peso neto: ' else 'Metraje: ' end
      || replace(to_char(r.cantidad_inicial, 'FM999999990.00'), '.', ',') || ' ' || r.unidad || E'\n'
      || 'Recibido: ' || to_char(r.fecha_codigo, 'DD/MM/YYYY');
end $$;
