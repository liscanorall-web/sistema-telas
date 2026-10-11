-- =====================================================================
-- 0004 · Aislamiento entre empresas (RLS) y permisos en la base de datos
-- Regla: aunque la aplicación tuviera un error, la base de datos no
-- devuelve ni acepta filas de una empresa a la que el usuario no pertenece.
-- Decisiones: D-01, D-08, regla obligatoria 7
-- =====================================================================

-- ---------------------------------------------------------------------
-- Funciones auxiliares (SECURITY DEFINER para no depender de RLS al consultar
-- membresías; viven en el esquema privado, que la API no expone)
-- ---------------------------------------------------------------------
create function privado.es_admin_plataforma() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select es_admin_plataforma and activo from public.perfil_usuario where id = auth.uid()), false)
$$;

create function privado.es_miembro(p_empresa uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1
    from public.membresia m
    join public.perfil_usuario u on u.id = m.usuario_id and u.activo
    join public.empresa e on e.id = m.empresa_id and e.activo
    where m.usuario_id = auth.uid() and m.empresa_id = p_empresa and m.activo)
$$;

-- ¿Tiene el usuario actual el permiso en esa empresa (y en esa sucursal, si se indica)?
create function privado.tiene_permiso(p_empresa uuid, p_permiso text, p_sucursal uuid default null)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1
    from public.membresia m
    join public.perfil_usuario u on u.id = m.usuario_id and u.activo
    join public.empresa e on e.id = m.empresa_id and e.activo
    join public.rol r on r.id = m.rol_id and r.activo
    join public.rol_permiso rp on rp.rol_id = m.rol_id
    where m.usuario_id = auth.uid()
      and m.empresa_id = p_empresa
      and m.activo
      and rp.permiso_codigo = p_permiso
      and (p_sucursal is null
           or m.todas_sucursales
           or exists (select 1 from public.membresia_sucursal ms
                      where ms.membresia_id = m.id and ms.sucursal_id = p_sucursal)))
$$;

create function privado.sucursal_de_almacen(p_almacen uuid) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select sucursal_id from public.almacen where id = p_almacen
$$;

create function privado.puede_ver_recepcion(p_recepcion uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.recepcion r
                 where r.id = p_recepcion
                   and privado.tiene_permiso(r.empresa_id, 'recepcion.ver', r.sucursal_id))
$$;

create function privado.comparte_empresa(p_usuario uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.membresia a
                 join public.membresia b on b.empresa_id = a.empresa_id and b.activo
                 where a.usuario_id = auth.uid() and a.activo and b.usuario_id = p_usuario)
$$;

-- ---------------------------------------------------------------------
-- Privilegios: nada para anónimos; lectura para autenticados (filtrada por RLS);
-- escritura directa solo en configuración y catálogo. Lo crítico (recepción,
-- piezas, eventos, aprobaciones) solo se modifica mediante funciones.
-- ---------------------------------------------------------------------
revoke all on all tables in schema public from anon, authenticated, public;
revoke all on all sequences in schema public from anon, authenticated, public;
revoke all on schema privado from anon, authenticated, public;
grant usage on schema public to authenticated;
grant usage on schema privado to authenticated;  -- necesario para evaluar políticas; funciones sin EXECUTE directo
revoke execute on all functions in schema privado from public, anon;
grant execute on all functions in schema privado to authenticated;

grant select on all tables in schema public to authenticated;
revoke select on public.contador_recepcion, public.contador_pieza from authenticated;

grant insert, update on public.sucursal, public.almacen, public.ubicacion,
                        public.rol, public.membresia, public.articulo, public.proveedor
  to authenticated;
grant insert, delete on public.rol_permiso, public.membresia_sucursal, public.conversion_unidad to authenticated;
grant update (nombre) on public.perfil_usuario to authenticated;

-- ---------------------------------------------------------------------
-- RLS activada en todas las tablas (el propietario, que ejecuta las funciones
-- SECURITY DEFINER, queda fuera; los usuarios de la API, siempre dentro)
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- Catálogos globales: legibles por cualquier usuario autenticado.
create policy leer on public.permiso       for select to authenticated using (true);
create policy leer on public.unidad_medida for select to authenticated using (true);

-- Perfiles: el propio y los de compañeros de empresa.
create policy leer on public.perfil_usuario for select to authenticated
  using (id = auth.uid() or privado.comparte_empresa(id) or privado.es_admin_plataforma());
create policy editar_propio on public.perfil_usuario for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- Empresa
create policy leer on public.empresa for select to authenticated
  using (privado.es_miembro(id) or privado.es_admin_plataforma());

-- Organización
create policy leer on public.sucursal for select to authenticated using (privado.es_miembro(empresa_id));
create policy crear on public.sucursal for insert to authenticated with check (privado.tiene_permiso(empresa_id, 'config.editar'));
create policy editar on public.sucursal for update to authenticated
  using (privado.tiene_permiso(empresa_id, 'config.editar')) with check (privado.tiene_permiso(empresa_id, 'config.editar'));

create policy leer on public.almacen for select to authenticated using (privado.es_miembro(empresa_id));
create policy crear on public.almacen for insert to authenticated with check (privado.tiene_permiso(empresa_id, 'config.editar'));
create policy editar on public.almacen for update to authenticated
  using (privado.tiene_permiso(empresa_id, 'config.editar')) with check (privado.tiene_permiso(empresa_id, 'config.editar'));

create policy leer on public.ubicacion for select to authenticated using (privado.es_miembro(empresa_id));
create policy crear on public.ubicacion for insert to authenticated with check (privado.tiene_permiso(empresa_id, 'config.editar'));
create policy editar on public.ubicacion for update to authenticated
  using (privado.tiene_permiso(empresa_id, 'config.editar')) with check (privado.tiene_permiso(empresa_id, 'config.editar'));

-- Seguridad: roles y membresías
create policy leer on public.rol for select to authenticated using (privado.es_miembro(empresa_id));
create policy crear on public.rol for insert to authenticated with check (privado.tiene_permiso(empresa_id, 'config.editar'));
create policy editar on public.rol for update to authenticated
  using (privado.tiene_permiso(empresa_id, 'config.editar')) with check (privado.tiene_permiso(empresa_id, 'config.editar'));

create policy leer on public.rol_permiso for select to authenticated using (privado.es_miembro(empresa_id));
create policy crear on public.rol_permiso for insert to authenticated with check (privado.tiene_permiso(empresa_id, 'config.editar'));
create policy borrar on public.rol_permiso for delete to authenticated using (privado.tiene_permiso(empresa_id, 'config.editar'));

create policy leer on public.membresia for select to authenticated
  using (usuario_id = auth.uid() or privado.tiene_permiso(empresa_id, 'config.ver'));
create policy crear on public.membresia for insert to authenticated with check (privado.tiene_permiso(empresa_id, 'config.editar'));
create policy editar on public.membresia for update to authenticated
  using (privado.tiene_permiso(empresa_id, 'config.editar')) with check (privado.tiene_permiso(empresa_id, 'config.editar'));

create policy leer on public.membresia_sucursal for select to authenticated using (privado.es_miembro(empresa_id));
create policy crear on public.membresia_sucursal for insert to authenticated with check (privado.tiene_permiso(empresa_id, 'config.editar'));
create policy borrar on public.membresia_sucursal for delete to authenticated using (privado.tiene_permiso(empresa_id, 'config.editar'));

-- Catálogo
create policy leer on public.articulo for select to authenticated using (privado.tiene_permiso(empresa_id, 'catalogo.ver'));
create policy crear on public.articulo for insert to authenticated with check (privado.tiene_permiso(empresa_id, 'catalogo.editar'));
create policy editar on public.articulo for update to authenticated
  using (privado.tiene_permiso(empresa_id, 'catalogo.editar')) with check (privado.tiene_permiso(empresa_id, 'catalogo.editar'));

create policy leer on public.conversion_unidad for select to authenticated using (privado.tiene_permiso(empresa_id, 'catalogo.ver'));
create policy crear on public.conversion_unidad for insert to authenticated with check (privado.tiene_permiso(empresa_id, 'catalogo.editar'));
create policy borrar on public.conversion_unidad for delete to authenticated using (privado.tiene_permiso(empresa_id, 'catalogo.editar'));

create policy leer on public.proveedor for select to authenticated using (privado.tiene_permiso(empresa_id, 'catalogo.ver'));
create policy crear on public.proveedor for insert to authenticated with check (privado.tiene_permiso(empresa_id, 'catalogo.editar'));
create policy editar on public.proveedor for update to authenticated
  using (privado.tiene_permiso(empresa_id, 'catalogo.editar')) with check (privado.tiene_permiso(empresa_id, 'catalogo.editar'));

-- Recepción y piezas: solo lectura directa, filtrada por empresa y sucursal.
create policy leer on public.recepcion for select to authenticated
  using (privado.tiene_permiso(empresa_id, 'recepcion.ver', sucursal_id));
create policy leer on public.recepcion_linea for select to authenticated
  using (privado.puede_ver_recepcion(recepcion_id));
create policy leer on public.pieza for select to authenticated
  using (privado.tiene_permiso(empresa_id, 'recepcion.ver', privado.sucursal_de_almacen(almacen_id)));
create policy leer on public.evento_pieza for select to authenticated
  using (exists (select 1 from public.pieza p where p.id = pieza_id));   -- hereda la política de pieza
create policy leer on public.incidencia for select to authenticated
  using (privado.puede_ver_recepcion(recepcion_id));
create policy leer on public.aprobacion_recepcion for select to authenticated
  using (privado.puede_ver_recepcion(recepcion_id));
create policy leer on public.etiqueta_impresion for select to authenticated
  using (exists (select 1 from public.pieza p where p.id = pieza_id));

-- Auditoría
create policy leer on public.auditoria for select to authenticated
  using (empresa_id is not null and privado.tiene_permiso(empresa_id, 'auditoria.ver'));
