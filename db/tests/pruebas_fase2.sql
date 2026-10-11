-- =====================================================================
-- Pruebas de aceptación de la Fase 2 (arquitectura técnica)
-- Se ejecutan contra una base recién migrada. Cada prueba deja una fila en
-- prueba.resultado; al final se imprime el resumen.
-- =====================================================================
\set ON_ERROR_STOP on
\pset footer off

create schema prueba;
create table prueba.resultado (n serial, bloque text, nombre text, ok boolean, detalle text);
grant usage on schema prueba to authenticated, anon;
grant insert, select on prueba.resultado to authenticated, anon;
grant usage on sequence prueba.resultado_n_seq to authenticated, anon;

create function prueba.como(u uuid) returns void language sql as
  $$ select set_config('request.jwt.claim.sub', u::text, false) $$;

create function prueba.ok(p_bloque text, p_cond boolean, p_nombre text, p_detalle text default null) returns void
language sql as $$ insert into prueba.resultado (bloque, nombre, ok, detalle) values (p_bloque, p_nombre, coalesce(p_cond, false), p_detalle) $$;

-- Ejecuta p_sql y espera que falle (opcionalmente con un mensaje que contenga p_patron).
create function prueba.falla(p_bloque text, p_sql text, p_nombre text, p_patron text default null) returns void
language plpgsql as $$
begin
  execute p_sql;
  insert into prueba.resultado (bloque, nombre, ok, detalle) values (p_bloque, p_nombre, false, 'NO falló');
exception when others then
  insert into prueba.resultado (bloque, nombre, ok, detalle)
  values (p_bloque, p_nombre, p_patron is null or sqlerrm ilike '%' || p_patron || '%', sqlerrm);
end $$;
grant execute on all functions in schema prueba to authenticated, anon;

-- ---------------------------------------------------------------------
-- Datos de prueba: usuarios
-- ---------------------------------------------------------------------
\set u_plataforma '00000000-0000-0000-0000-000000000001'
\set u_admin_a    '00000000-0000-0000-0000-0000000000a1'
\set u_gerente_a  '00000000-0000-0000-0000-0000000000a2'
\set u_recep_a    '00000000-0000-0000-0000-0000000000a3'
\set u_alm_norte  '00000000-0000-0000-0000-0000000000a4'
\set u_auditor_a  '00000000-0000-0000-0000-0000000000a5'
\set u_admin_b    '00000000-0000-0000-0000-0000000000b1'

insert into auth.users (id, email) values
  (:'u_plataforma', 'plataforma@prueba'), (:'u_admin_a', 'admin.a@prueba'), (:'u_gerente_a', 'gerente.a@prueba'),
  (:'u_recep_a', 'recepcion.a@prueba'), (:'u_alm_norte', 'almacen.norte@prueba'),
  (:'u_auditor_a', 'auditor.a@prueba'), (:'u_admin_b', 'admin.b@prueba');
insert into public.perfil_usuario (id, nombre, es_admin_plataforma) values
  (:'u_plataforma', 'Administración plataforma', true), (:'u_admin_a', 'Admin A', false),
  (:'u_gerente_a', 'Gerente A', false), (:'u_recep_a', 'Recepción A', false),
  (:'u_alm_norte', 'Almacén Norte A', false), (:'u_auditor_a', 'Auditor A', false), (:'u_admin_b', 'Admin B', false);

-- ---------------------------------------------------------------------
-- Alta de empresas (solo plataforma)
-- ---------------------------------------------------------------------
set role authenticated;
select prueba.como(:'u_admin_a');
select prueba.falla('Plataforma', $$select public.crear_empresa('Intrusa', null, null)$$,
  'Un usuario normal no puede crear empresas', 'plataforma');

select prueba.como(:'u_plataforma');
select public.crear_empresa('Textiles A', 'J-0001', :'u_admin_a') as emp_a \gset
select public.crear_empresa('Comercial B', 'J-0002', :'u_admin_b') as emp_b \gset
select prueba.ok('Plataforma', (select count(*) from public.rol where empresa_id = :'emp_a') = 0,
  'La administración de plataforma no ve los datos internos de una empresa');

-- ---------------------------------------------------------------------
-- Empresa A: organización, catálogo y equipo
-- ---------------------------------------------------------------------
select prueba.como(:'u_admin_a');
select prueba.ok('Plataforma', (select count(*) from public.rol where empresa_id = :'emp_a') = 5,
  'Cada empresa nueva nace con 5 roles de partida');
insert into public.sucursal (empresa_id, codigo, nombre, ciudad) values (:'emp_a', 'NORTE', 'Sucursal Norte', 'Ciudad Norte') returning id as suc_norte \gset
insert into public.sucursal (empresa_id, codigo, nombre, ciudad) values (:'emp_a', 'SUR', 'Sucursal Sur', 'Ciudad Sur') returning id as suc_sur \gset
insert into public.almacen (empresa_id, sucursal_id, codigo, nombre) values (:'emp_a', :'suc_norte', 'ALM-N', 'Almacén Norte') returning id as alm_norte \gset
insert into public.almacen (empresa_id, sucursal_id, codigo, nombre) values (:'emp_a', :'suc_sur', 'ALM-S', 'Almacén Sur') returning id as alm_sur \gset
insert into public.articulo (empresa_id, codigo, descripcion, material, color, abreviatura, unidad_control, cantidad_max_pieza)
  values (:'emp_a', 'MUTJ001', 'Muselina blanca', 'Muselina', 'Blanco', 'MUB', 'kg', 80) returning id as art_mub \gset
insert into public.articulo (empresa_id, codigo, descripcion, material, color, abreviatura, unidad_control)
  values (:'emp_a', 'MUTJ002', 'Muselina negra', 'Muselina', 'Negro', 'MUN', 'kg') returning id as art_mun \gset
insert into public.articulo (empresa_id, codigo, descripcion, material, color, abreviatura, unidad_control)
  values (:'emp_a', 'PPTJ001', 'Polipiel marrón', 'Polipiel', 'Marrón', 'PPM', 'm') returning id as art_ppm \gset
insert into public.proveedor (empresa_id, codigo, nombre) values (:'emp_a', 'PROV1', 'Proveedor Uno') returning id as prov_a \gset

select id as rol_gerente from public.rol where empresa_id = :'emp_a' and nombre = 'Gerente' \gset
select id as rol_recep   from public.rol where empresa_id = :'emp_a' and nombre = 'Responsable de recepción' \gset
select id as rol_alm     from public.rol where empresa_id = :'emp_a' and nombre = 'Personal de almacén' \gset
select id as rol_aud     from public.rol where empresa_id = :'emp_a' and nombre = 'Auditor' \gset
insert into public.membresia (empresa_id, usuario_id, rol_id, todas_sucursales) values
  (:'emp_a', :'u_gerente_a', :'rol_gerente', true), (:'emp_a', :'u_recep_a', :'rol_recep', true),
  (:'emp_a', :'u_auditor_a', :'rol_aud', true);
insert into public.membresia (empresa_id, usuario_id, rol_id, todas_sucursales)
  values (:'emp_a', :'u_alm_norte', :'rol_alm', false) returning id as memb_alm \gset
insert into public.membresia_sucursal (empresa_id, membresia_id, sucursal_id) values (:'emp_a', :'memb_alm', :'suc_norte');

select prueba.falla('Aislamiento',
  format($$select public.crear_empresa('x', null, null)$$), 'Admin de empresa tampoco crea empresas', 'plataforma');

select prueba.falla('Aislamiento', format(
  $$insert into public.articulo (empresa_id, codigo, descripcion, abreviatura, unidad_control)
    values (%L, 'MUTJ009', 'Duplicada', 'MUB', 'kg')$$, :'emp_a'),
  'La abreviatura es única dentro de la empresa (P-07)', 'duplicate');

-- ---------------------------------------------------------------------
-- Empresa B: mismo código de artículo y misma abreviatura (permitido)
-- ---------------------------------------------------------------------
select prueba.como(:'u_admin_b');
insert into public.sucursal (empresa_id, codigo, nombre) values (:'emp_b', 'CENTRO', 'Sucursal Centro') returning id as suc_b \gset
insert into public.almacen (empresa_id, sucursal_id, codigo, nombre) values (:'emp_b', :'suc_b', 'ALM-C', 'Almacén Centro') returning id as alm_b \gset
insert into public.articulo (empresa_id, codigo, descripcion, abreviatura, unidad_control)
  values (:'emp_b', 'MUTJ001', 'Muselina blanca B', 'MUB', 'kg') returning id as art_b \gset
insert into public.proveedor (empresa_id, codigo, nombre) values (:'emp_b', 'PROVB', 'Proveedor B') returning id as prov_b \gset
select (public.crear_recepcion(:'emp_b', :'prov_b', 'factura', 'FB-1', '2026-10-11', :'alm_b')).id as rec_b \gset
select (public.agregar_linea_recepcion(:'rec_b', :'art_b', 500, null)).id as lin_b \gset
select (public.registrar_pieza(:'lin_b', 30.10, gen_random_uuid())).codigo as codigo_b \gset

-- ---------------------------------------------------------------------
-- Recepción en A (responsable de recepción)
-- ---------------------------------------------------------------------
select prueba.como(:'u_recep_a');
select (r).id as rec1, (r).numero as rec1_numero
  from (select public.crear_recepcion(:'emp_a', :'prov_a', 'factura', 'F-1001', '2026-10-11', :'alm_norte') r) x \gset
select (public.agregar_linea_recepcion(:'rec1', :'art_mub', 100, 4)).id as lin_mub \gset
select (public.agregar_linea_recepcion(:'rec1', :'art_mun', 50, null)).id as lin_mun \gset

select (public.registrar_pieza(:'lin_mub', 25.40, '11111111-1111-1111-1111-111111111111')).codigo as c1 \gset
select (public.registrar_pieza(:'lin_mub', 24.85, gen_random_uuid())).id as p2 \gset
select (public.registrar_pieza(:'lin_mub', 26.10, gen_random_uuid())).codigo as c3 \gset
select (public.registrar_pieza(:'lin_mun', 23.00, gen_random_uuid())).codigo as c_mun \gset

-- ---------------------------------------------------------------------
-- BLOQUE: identificadores
-- ---------------------------------------------------------------------
select prueba.ok('Identificador', :'c1' = '20261011-MUB-001', 'Primera pieza: 20261011-MUB-001', :'c1');
select prueba.ok('Identificador', :'c3' = '20261011-MUB-003', 'Tercera pieza: 20261011-MUB-003', :'c3');
select prueba.ok('Identificador', :'c_mun' = '20261011-MUN-001', 'Otro artículo reinicia su correlativo', :'c_mun');
select prueba.ok('Identificador', :'codigo_b' = '20261011-MUB-001',
  'La empresa B tiene su propio 20261011-MUB-001 sin chocar con A (P-03)', :'codigo_b');

select (public.registrar_pieza(:'lin_mub', 25.40, '11111111-1111-1111-1111-111111111111')).codigo as c1_reintento \gset
select prueba.ok('Identificador', :'c1_reintento' = :'c1'
  and (select count(*) from public.pieza where recepcion_id = :'rec1') = 4,
  'Un reintento de red con la misma clave no duplica la pieza', :'c1_reintento');

select prueba.como(:'u_gerente_a');
select public.anular_pieza(:'p2', 'Peso mal tecleado') is not null as x \gset
select prueba.como(:'u_recep_a');
select (public.registrar_pieza(:'lin_mub', 24.58, gen_random_uuid())).codigo as c4 \gset
select prueba.ok('Identificador', :'c4' = '20261011-MUB-004',
  'Un número anulado (002) nunca se reutiliza: la siguiente es 004', :'c4');

select prueba.falla('Identificador', format($$select public.registrar_pieza(%L, 25.123, gen_random_uuid())$$, :'lin_mub'),
  'Se rechazan más de 2 decimales (P-08)', '2 decimales');
select prueba.falla('Identificador', format($$select public.registrar_pieza(%L, 1250, gen_random_uuid())$$, :'lin_mub'),
  'Se rechaza un peso por encima del máximo del artículo', 'supera el máximo');
select prueba.falla('Identificador', format($$select public.registrar_pieza(%L, 0, gen_random_uuid())$$, :'lin_mub'),
  'Se rechaza un peso cero', 'mayor que cero');

reset role;
-- Simula 998 piezas ya emitidas ese día para probar el paso a 4 dígitos (P-05).
insert into public.contador_pieza (empresa_id, fecha, abreviatura, ultimo) values (:'emp_a', '2026-10-12', 'PPM', 998);
set role authenticated;
select prueba.como(:'u_recep_a');
select (public.crear_recepcion(:'emp_a', :'prov_a', 'factura', 'F-1002', '2026-10-12', :'alm_norte')).id as rec_ppm \gset
select (public.agregar_linea_recepcion(:'rec_ppm', :'art_ppm', 300, null)).id as lin_ppm \gset
select (public.registrar_pieza(:'lin_ppm', 50.00, gen_random_uuid())).codigo as c999 \gset
select (public.registrar_pieza(:'lin_ppm', 48.50, gen_random_uuid())).codigo as c1000 \gset
select prueba.ok('Identificador', :'c999' = '20261012-PPM-999' and :'c1000' = '20261012-PPM-1000',
  'Pasado el 999 el correlativo crece a 4 dígitos (P-05)', :'c999' || ' / ' || :'c1000');

select prueba.como(:'u_admin_a');
select prueba.falla('Identificador', format($$update public.articulo set abreviatura = 'MBL' where id = %L$$, :'art_mub'),
  'La abreviatura queda bloqueada tras emitir piezas (P-07)', 'no puede cambiarse');

-- ---------------------------------------------------------------------
-- BLOQUE: inmutabilidad e historial
-- ---------------------------------------------------------------------
select prueba.como(:'u_admin_a');
select prueba.falla('Historial', format($$insert into public.pieza (empresa_id, codigo, fecha_codigo, abreviatura,
  correlativo, articulo_id, recepcion_id, linea_id, unidad, cantidad_inicial, cantidad_actual, almacen_id,
  clave_idempotencia, creado_por) values (%L, 'FALSA', '2026-10-11', 'MUB', 99, %L, %L, %L, 'kg', 1, 1, %L,
  gen_random_uuid(), %L)$$, :'emp_a', :'art_mub', :'rec1', :'lin_mub', :'alm_norte', :'u_admin_a'),
  'Nadie inserta piezas directamente: solo mediante registrar_pieza', 'permission denied');
select prueba.falla('Historial', format($$update public.pieza set estado = 'liberada' where recepcion_id = %L$$, :'rec1'),
  'Nadie cambia el estado de una pieza directamente (ni el admin de empresa)', 'permission denied');
select prueba.falla('Historial', $$delete from public.evento_pieza$$, 'Los eventos no se borran desde la API', 'permission denied');

reset role;   -- incluso el propietario de la base, que salta RLS, choca con los disparadores
select prueba.falla('Historial', format($$update public.pieza set cantidad_inicial = 30 where codigo = %L$$, :'c1'),
  'El peso inicial de una pieza es inmutable incluso para el administrador de la base', 'no pueden modificarse');
select prueba.falla('Historial', format($$update public.pieza set codigo = 'OTRO' where codigo = %L$$, :'c1'),
  'El identificador de una pieza es inmutable', 'no pueden modificarse');
select prueba.falla('Historial', format($$delete from public.pieza where codigo = %L$$, :'c1'),
  'Las piezas no se borran: se anulan', 'no se borran');
select prueba.falla('Historial', $$update public.evento_pieza set motivo = 'x'$$,
  'Los eventos de pieza no se editan', 'histórica');
select prueba.falla('Historial', $$delete from public.auditoria$$, 'La auditoría no se borra', 'histórica');
select prueba.ok('Historial', (select count(*) from public.evento_pieza e join public.pieza p on p.id = e.pieza_id
                                where p.id = :'p2' and e.tipo = 'anulada' and e.motivo = 'Peso mal tecleado') = 1,
  'La anulación queda como evento con su motivo; la pieza original sigue visible');
select prueba.ok('Historial', (select count(*) from public.auditoria where tabla = 'pieza' and usuario_id = :'u_recep_a') >= 4,
  'La auditoría registra quién creó cada pieza');
set role authenticated;

-- ---------------------------------------------------------------------
-- BLOQUE: aislamiento entre empresas (criterio de aceptación de la Fase 2)
-- ---------------------------------------------------------------------
select prueba.como(:'u_admin_b');
select prueba.ok('Aislamiento', (select count(*) from public.empresa) = 1, 'B solo ve su propia empresa');
select prueba.ok('Aislamiento', (select count(*) from public.articulo where empresa_id = :'emp_a') = 0, 'B no ve artículos de A');
select prueba.ok('Aislamiento', (select count(*) from public.recepcion where empresa_id = :'emp_a') = 0, 'B no ve recepciones de A');
select prueba.ok('Aislamiento', (select count(*) from public.pieza where empresa_id = :'emp_a') = 0, 'B no ve piezas de A');
select prueba.ok('Aislamiento', (select count(*) from public.evento_pieza where empresa_id = :'emp_a') = 0, 'B no ve eventos de A');
select prueba.ok('Aislamiento', (select count(*) from public.vista_cuadre_recepcion where empresa_id = :'emp_a') = 0, 'B no ve el cuadre de A');
select prueba.ok('Aislamiento', (select count(*) from public.membresia where empresa_id = :'emp_a') = 0, 'B no ve el equipo de A');
select prueba.ok('Aislamiento', (select count(*) from public.perfil_usuario where id = :'u_gerente_a') = 0, 'B no ve los perfiles de A');
select prueba.falla('Aislamiento', format($$insert into public.articulo (empresa_id, codigo, descripcion, abreviatura, unidad_control)
  values (%L, 'HACK01', 'Intruso', 'HCK', 'kg')$$, :'emp_a'), 'B no puede crear artículos en A', 'row-level security');
update public.articulo set descripcion = 'Modificado por B' where id = :'art_mub';
select prueba.falla('Aislamiento', format($$insert into public.membresia (empresa_id, usuario_id, rol_id, todas_sucursales)
  values (%L, %L, %L, true)$$, :'emp_a', :'u_admin_b', :'rol_gerente'), 'B no puede darse acceso a A', 'row-level security');
select prueba.falla('Aislamiento', format($$select public.crear_recepcion(%L, %L, 'factura', 'X', '2026-10-11', %L)$$,
  :'emp_a', :'prov_a', :'alm_norte'), 'B no puede abrir recepciones en A', 'permiso');
select prueba.falla('Aislamiento', format($$select public.registrar_pieza(%L, 10, gen_random_uuid())$$, :'lin_mub'),
  'B no puede registrar piezas en A', 'permiso');
select prueba.falla('Aislamiento', format($$select public.cuadre_recepcion(%L)$$, :'rec1'), 'B no puede pedir el cuadre de A', 'permiso');
select prueba.falla('Aislamiento', format($$select public.contenido_qr(%L)$$, :'p2'),
  'B no puede leer el QR de una pieza de A', 'permiso');
select prueba.falla('Aislamiento', format($$insert into public.almacen (empresa_id, sucursal_id, codigo, nombre) values (%L, %L, 'X', 'X')$$,
  :'emp_b', :'suc_norte'), 'Clave foránea compuesta: un almacén de B no puede colgar de una sucursal de A', 'foreign key');

reset role;
select prueba.ok('Aislamiento', (select descripcion from public.articulo where id = :'art_mub') = 'Muselina blanca',
  'Un UPDATE de B sobre un artículo de A no cambia nada');
set role anon;
select prueba.falla('Aislamiento', $$select count(*) from public.pieza$$, 'Un visitante sin sesión no lee nada', 'permission denied');
select prueba.falla('Aislamiento', format($$select public.registrar_pieza(%L, 10, gen_random_uuid())$$, :'lin_mub'),
  'Un visitante sin sesión no ejecuta operaciones', 'permission denied');
reset role;
set role authenticated;

-- ---------------------------------------------------------------------
-- BLOQUE: permisos y alcance por sucursal
-- ---------------------------------------------------------------------
select prueba.como(:'u_recep_a');
select (public.crear_recepcion(:'emp_a', :'prov_a', 'factura', 'F-2001', '2026-10-11', :'alm_sur')).id as rec_sur \gset
select (public.agregar_linea_recepcion(:'rec_sur', :'art_mub', 60, null)).id as lin_sur \gset

select prueba.como(:'u_alm_norte');
select prueba.ok('Permisos', (public.registrar_pieza(:'lin_mub', 22.22, gen_random_uuid())).codigo = '20261011-MUB-005',
  'Almacén Norte registra piezas en una recepción del Norte');
select prueba.falla('Permisos', format($$select public.registrar_pieza(%L, 20, gen_random_uuid())$$, :'lin_sur'),
  'Almacén Norte NO registra piezas en la sucursal Sur', 'permiso');
select prueba.ok('Permisos', (select count(*) from public.recepcion where id = :'rec_sur') = 0,
  'Almacén Norte ni siquiera ve las recepciones del Sur');
select prueba.falla('Permisos', format($$select public.crear_recepcion(%L, %L, 'factura', 'X', '2026-10-11', %L)$$,
  :'emp_a', :'prov_a', :'alm_norte'), 'Personal de almacén no abre recepciones', 'recepcion.crear');

select prueba.como(:'u_auditor_a');
select prueba.ok('Permisos', (select count(*) from public.pieza where empresa_id = :'emp_a') > 0, 'El auditor consulta piezas');
select prueba.ok('Permisos', (select count(*) from public.auditoria where empresa_id = :'emp_a') > 0, 'El auditor consulta la auditoría');
select prueba.falla('Permisos', format($$insert into public.proveedor (empresa_id, codigo, nombre) values (%L, 'P9', 'X')$$, :'emp_a'),
  'El auditor no edita el catálogo', 'row-level security');

select prueba.como(:'u_recep_a');
select prueba.ok('Permisos', (select count(*) from public.auditoria) = 0, 'Recepción no ve la auditoría');

-- ---------------------------------------------------------------------
-- BLOQUE: flujo de recepción, cuadre, doble control y liberación
-- ---------------------------------------------------------------------
select prueba.como(:'u_recep_a');
select prueba.ok('Flujo', (select count(*) from public.pieza where recepcion_id = :'rec1' and estado = 'liberada') = 0,
  'Recién registradas, ninguna pieza está disponible (D-06)');
select prueba.falla('Flujo', format($$select public.cerrar_registro(%L, 99)$$, :'rec1'),
  'Cerrar con una versión vieja se rechaza con aviso (concurrencia)', 'cambió mientras');
select version as v from public.recepcion where id = :'rec1' \gset
select (public.cerrar_registro(:'rec1', :v)).version as v \gset
select prueba.falla('Flujo', format($$select public.registrar_pieza(%L, 20, gen_random_uuid())$$, :'lin_mub'),
  'Con el registro cerrado ya no entran piezas', 'ya no admite');

-- incidencia sobre una pieza: quien la registra no puede resolverla
select id as p_danio from public.pieza where codigo = :'c3' \gset
select (public.registrar_incidencia(:'rec1', 'danio', 'Rollo con la funda rota', :'p_danio')).id as inc1 \gset
select prueba.como(:'u_gerente_a');
select (public.enviar_a_aprobacion(:'rec1', :v)).version as v \gset
select prueba.falla('Flujo', format($$select public.decidir_recepcion(%L, %s, 'aprobada', 'ok')$$, :'rec1', :v),
  'Doble control: quien envía a aprobación no puede aprobar (P-11)', 'Doble control');

-- Para el resto del flujo, la envía el responsable de recepción en otra recepción
select prueba.como(:'u_recep_a');
select (public.crear_recepcion(:'emp_a', :'prov_a', 'factura', 'F-3001', '2026-10-11', :'alm_norte')).id as rec2 \gset
select (public.agregar_linea_recepcion(:'rec2', :'art_mub', 100, 4)).id as lin2 \gset
select public.registrar_pieza(:'lin2', 25.00, gen_random_uuid()) is not null as x \gset
select public.registrar_pieza(:'lin2', 24.00, gen_random_uuid()) is not null as x \gset
select public.registrar_pieza(:'lin2', 25.00, gen_random_uuid()) is not null as x \gset
select public.registrar_pieza(:'lin2', 20.00, gen_random_uuid()) is not null as x \gset
select version as v2 from public.recepcion where id = :'rec2' \gset
select (public.cerrar_registro(:'rec2', :v2)).version as v2 \gset
select (public.enviar_a_aprobacion(:'rec2', :v2)).version as v2 \gset
select prueba.falla('Flujo', format($$select public.decidir_recepcion(%L, %s, 'aprobada')$$, :'rec2', :v2),
  'Responsable de recepción no puede aprobar', 'recepcion.aprobar');

select prueba.como(:'u_gerente_a');
select public.cuadre_recepcion(:'rec2') as cuadre2 \gset
select prueba.ok('Flujo', (:'cuadre2'::jsonb -> 'lineas' -> 0 ->> 'cantidad_recibida')::numeric = 94.00
  and (:'cuadre2'::jsonb -> 'lineas' -> 0 ->> 'diferencia')::numeric = -6.00
  and (:'cuadre2'::jsonb -> 'lineas' -> 0 ->> 'diferencia_pct')::numeric = -6.00,
  'Cuadre: facturado 100 kg, recibido 94 kg, diferencia -6 kg (-6 %); nada se ajusta solo',
  :'cuadre2'::jsonb -> 'lineas' -> 0 ->> 'cantidad_recibida');
select prueba.falla('Flujo', format($$select public.liberar_piezas(%L)$$, :'rec2'),
  'No se libera nada antes de la aprobación del gerente', 'aprobada por el gerente');
select prueba.falla('Flujo', format($$select public.decidir_recepcion(%L, %s, 'aprobada')$$, :'rec2', :v2),
  'Con diferencias, el gerente debe indicar el motivo', 'motivo');
select (public.decidir_recepcion(:'rec2', :v2, 'aprobada', 'Faltan 6 kg; se reclamarán al proveedor')).estado as est2 \gset
select prueba.ok('Flujo', :'est2' = 'verificada', 'Aprobada por el gerente: recepción verificada', :'est2');
select prueba.ok('Flujo', (select count(*) from public.aprobacion_recepcion
                            where recepcion_id = :'rec2' and aprobado_por = :'u_gerente_a' and cuadre ? 'lineas') = 1,
  'La decisión queda guardada con la firma del gerente y la foto del cuadre');
select prueba.ok('Flujo', (select count(*) from public.pieza where recepcion_id = :'rec2' and estado = 'liberada') = 0,
  'Aprobar no libera: las piezas siguen en cuarentena (P-10)');
select public.liberar_piezas(:'rec2') as liberadas \gset
select prueba.ok('Flujo', :liberadas = 4
  and (select estado from public.recepcion where id = :'rec2') = 'cerrada',
  'Liberadas las 4 piezas, la recepción se cierra sola', :liberadas || ' liberadas');

-- incidencia en rec1: la resuelve alguien distinto de quien la abrió
select prueba.como(:'u_recep_a');
select prueba.falla('Flujo', format($$select public.resolver_incidencia(%L, true, 'ok')$$, :'inc1'),
  'Recepción no resuelve incidencias (no tiene ese permiso)', 'resolver_incidencia');
select prueba.como(:'u_gerente_a');
select (public.resolver_incidencia(:'inc1', false, 'Rollo dañado, se devuelve')).abierta as abierta \gset
select prueba.ok('Flujo', (select estado from public.pieza where id = :'p_danio') = 'rechazada',
  'Incidencia resuelta como no aceptable: la pieza queda rechazada con su historial');

-- rechazo completo
select prueba.como(:'u_recep_a');
select prueba.falla('Flujo', format($$select public.decidir_recepcion(%L, %s, 'rechazada', 'x')$$, :'rec1', :v),
  'Responsable de recepción no rechaza', 'recepcion.aprobar');
select prueba.como(:'u_admin_a');
select (public.decidir_recepcion(:'rec1', :v, 'rechazada', 'Documento no corresponde')).estado as est1 \gset
select prueba.ok('Flujo', :'est1' = 'rechazada'
  and not exists (select 1 from public.pieza where recepcion_id = :'rec1' and estado in ('en_cuarentena', 'liberada')),
  'Recepción rechazada: ninguna de sus piezas queda disponible', :'est1');

-- doble control también para incidencias: el admin la registra y no puede resolverla él mismo
select prueba.como(:'u_recep_a');
select (public.crear_recepcion(:'emp_a', :'prov_a', 'factura', 'F-4001', '2026-10-11', :'alm_norte')).id as rec3 \gset
select (public.agregar_linea_recepcion(:'rec3', :'art_mun', 30, 1)).id as lin3 \gset
select (public.registrar_pieza(:'lin3', 29.90, gen_random_uuid())).id as p3 \gset
select prueba.como(:'u_admin_a');
select (public.registrar_incidencia(:'rec3', 'danio', 'Borde manchado', :'p3')).id as inc3 \gset
select prueba.falla('Flujo', format($$select public.resolver_incidencia(%L, true, 'Aceptable')$$, :'inc3'),
  'Doble control: quien registra una incidencia no puede resolverla (P-11)', 'Doble control');
select prueba.como(:'u_gerente_a');
select (public.resolver_incidencia(:'inc3', true, 'Mancha en el borde, aceptable')).abierta as abierta3 \gset
select prueba.ok('Flujo', (select estado from public.pieza where id = :'p3') = 'en_cuarentena',
  'Incidencia aceptada por otra persona: la pieza vuelve a cuarentena para liberarse con las demás');

-- ---------------------------------------------------------------------
-- BLOQUE: etiqueta y QR (P-14, P-16)
-- ---------------------------------------------------------------------
select prueba.como(:'u_alm_norte');
select id as p_qr from public.pieza where recepcion_id = :'rec2' order by correlativo limit 1 \gset
select public.contenido_qr(:'p_qr') as qr \gset
select prueba.ok('Etiqueta', split_part(:'qr', E'\n', 1) ~ '^20261011-MUB-\d{3}$'
  and split_part(:'qr', E'\n', 2) = 'MUTJ001 Muselina blanca'
  and split_part(:'qr', E'\n', 3) ~ '^Peso neto: \d+,\d{2} kg$',
  'El QR lleva la cédula del rollo: identificador, artículo y peso neto', replace(:'qr', E'\n', ' | '));
select public.registrar_impresion_etiqueta(:'p_qr') as imp1 \gset
select public.registrar_impresion_etiqueta(:'p_qr') as imp2 \gset
select prueba.ok('Etiqueta', :imp1 = 1 and :imp2 = 2, 'Cada impresión y reimpresión queda numerada y registrada');

-- ---------------------------------------------------------------------
reset role;
\echo
\echo '================ RESULTADOS ================'
select bloque, count(*) filter (where ok) as superadas, count(*) as total
  from prueba.resultado group by bloque order by min(n);
select n, bloque, nombre, detalle from prueba.resultado where not ok order by n;
select count(*) filter (where ok) || ' de ' || count(*) || ' pruebas superadas' as resumen from prueba.resultado;
