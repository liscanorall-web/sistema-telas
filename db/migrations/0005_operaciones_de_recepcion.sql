-- =====================================================================
-- 0005 · Operaciones de recepción (funciones que la aplicación invoca)
-- Todo cambio en recepciones y piezas pasa por aquí: cada función comprueba
-- permiso, empresa, sucursal y estado dentro de una sola transacción.
-- Decisiones: D-03, D-04, D-06, D-07, P-04..P-11, P-13, P-16
-- =====================================================================

-- ---------------------------------------------------------------------
-- Auxiliares
-- ---------------------------------------------------------------------
create function privado.usuario_actual() returns uuid
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v uuid := auth.uid();
begin
  if v is null or not exists (select 1 from public.perfil_usuario where id = v and activo) then
    raise exception 'Sesión no válida: inicia sesión de nuevo' using errcode = '28000';
  end if;
  return v;
end $$;

create function privado.exigir_permiso(p_empresa uuid, p_permiso text, p_sucursal uuid default null)
returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not privado.tiene_permiso(p_empresa, p_permiso, p_sucursal) then
    raise exception 'No tienes permiso para esta acción (%)', p_permiso using errcode = '42501';
  end if;
end $$;

create function privado.registrar_evento(
  p_empresa uuid, p_pieza uuid, p_tipo text,
  p_antes public.estado_pieza, p_despues public.estado_pieza,
  p_datos jsonb default '{}'::jsonb, p_motivo text default null)
returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into public.evento_pieza (empresa_id, pieza_id, tipo, estado_anterior, estado_nuevo, datos, motivo, usuario_id)
  values (p_empresa, p_pieza, p_tipo, p_antes, p_despues, coalesce(p_datos, '{}'::jsonb), p_motivo, auth.uid())
$$;

-- Cierra la recepción cuando ya no le queda ninguna pieza por resolver.
create function privado.intentar_cerrar(p_recepcion uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update public.recepcion r
     set estado = 'cerrada', version = version + 1
   where r.id = p_recepcion
     and r.estado = 'verificada'
     and not exists (select 1 from public.pieza p
                     where p.recepcion_id = r.id and p.estado in ('en_cuarentena', 'pendiente_autorizacion'));
end $$;

-- ---------------------------------------------------------------------
-- Alta de empresa (solo administración de plataforma) con roles de partida
-- ---------------------------------------------------------------------
create function public.crear_empresa(p_nombre text, p_ident_fiscal text, p_administrador uuid)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_empresa uuid;
  v_rol uuid;
  plantilla record;
begin
  perform privado.usuario_actual();
  if not privado.es_admin_plataforma() then
    raise exception 'Solo la administración de la plataforma puede crear empresas' using errcode = '42501';
  end if;

  insert into public.empresa (nombre, ident_fiscal) values (p_nombre, p_ident_fiscal) returning id into v_empresa;
  insert into public.contador_recepcion (empresa_id) values (v_empresa);

  for plantilla in
    select * from (values
      ('Administrador de empresa', 'Todo dentro de su empresa',
        array(select codigo from public.permiso)),
      ('Gerente', 'Aprueba recepciones con el cuadre, libera piezas y resuelve incidencias',
        array['config.ver','catalogo.ver','catalogo.editar','recepcion.ver','recepcion.crear',
              'recepcion.verificar','recepcion.aprobar','recepcion.anular','pieza.liberar',
              'pieza.resolver_incidencia','etiqueta.imprimir','auditoria.ver']),
      ('Responsable de recepción', 'Abre recepciones, registra piezas y las envía al gerente',
        array['catalogo.ver','recepcion.ver','recepcion.crear','recepcion.registrar_pieza',
              'recepcion.verificar','etiqueta.imprimir']),
      ('Personal de almacén', 'Registra piezas e imprime etiquetas',
        array['catalogo.ver','recepcion.ver','recepcion.registrar_pieza','etiqueta.imprimir']),
      ('Auditor', 'Solo consulta',
        array['config.ver','catalogo.ver','recepcion.ver','auditoria.ver'])
    ) as t(nombre, descripcion, permisos)
  loop
    insert into public.rol (empresa_id, nombre, descripcion)
    values (v_empresa, plantilla.nombre, plantilla.descripcion) returning id into v_rol;
    insert into public.rol_permiso (empresa_id, rol_id, permiso_codigo)
    select v_empresa, v_rol, unnest(plantilla.permisos);
    if plantilla.nombre = 'Administrador de empresa' and p_administrador is not null then
      insert into public.membresia (empresa_id, usuario_id, rol_id, todas_sucursales)
      values (v_empresa, p_administrador, v_rol, true);
    end if;
  end loop;

  return v_empresa;
end $$;

-- ---------------------------------------------------------------------
-- 1. Abrir recepción
-- ---------------------------------------------------------------------
create function public.crear_recepcion(
  p_empresa uuid, p_proveedor uuid, p_documento_tipo text, p_documento_numero text,
  p_fecha_recepcion date, p_almacen uuid, p_observaciones text default null)
returns public.recepcion
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_usuario uuid := privado.usuario_actual();
  v_sucursal uuid;
  v_numero bigint;
  v_rec public.recepcion;
begin
  select sucursal_id into v_sucursal from public.almacen
   where id = p_almacen and empresa_id = p_empresa and activo;
  if v_sucursal is null then
    raise exception 'El almacén no existe o no pertenece a esta empresa' using errcode = '23503';
  end if;
  perform privado.exigir_permiso(p_empresa, 'recepcion.crear', v_sucursal);

  insert into public.contador_recepcion (empresa_id, ultimo) values (p_empresa, 1)
  on conflict (empresa_id) do update set ultimo = contador_recepcion.ultimo + 1
  returning ultimo into v_numero;

  insert into public.recepcion (empresa_id, numero, proveedor_id, documento_tipo, documento_numero,
                                fecha_recepcion, sucursal_id, almacen_id, observaciones, responsable_id)
  values (p_empresa, 'REC-' || lpad(v_numero::text, 6, '0'), p_proveedor, p_documento_tipo,
          p_documento_numero, p_fecha_recepcion, v_sucursal, p_almacen, p_observaciones, v_usuario)
  returning * into v_rec;
  return v_rec;
end $$;

-- ---------------------------------------------------------------------
-- 2. Cargar línea esperada (cantidad según factura; null = no esperado)
-- ---------------------------------------------------------------------
create function public.agregar_linea_recepcion(
  p_recepcion uuid, p_articulo uuid, p_cantidad_esperada numeric, p_piezas_esperadas integer default null)
returns public.recepcion_linea
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_usuario uuid := privado.usuario_actual();
  v_rec public.recepcion;
  v_linea public.recepcion_linea;
begin
  select * into v_rec from public.recepcion where id = p_recepcion for update;
  if not found then raise exception 'La recepción no existe' using errcode = '23503'; end if;
  perform privado.exigir_permiso(v_rec.empresa_id, 'recepcion.crear', v_rec.sucursal_id);
  if v_rec.estado <> 'en_preparacion' then
    raise exception 'Solo se agregan artículos a una recepción en preparación (estado actual: %)', v_rec.estado;
  end if;
  if not exists (select 1 from public.articulo where id = p_articulo and empresa_id = v_rec.empresa_id and activo) then
    raise exception 'El artículo no existe, está inactivo o es de otra empresa' using errcode = '23503';
  end if;

  insert into public.recepcion_linea (empresa_id, recepcion_id, articulo_id, cantidad_esperada, piezas_esperadas)
  values (v_rec.empresa_id, p_recepcion, p_articulo, p_cantidad_esperada, p_piezas_esperadas)
  returning * into v_linea;

  if p_cantidad_esperada is null then
    insert into public.incidencia (empresa_id, recepcion_id, tipo, descripcion, creado_por)
    select v_rec.empresa_id, p_recepcion, 'articulo_no_esperado',
           'Llegó ' || a.codigo || ' (' || a.descripcion || '), que no figura en el documento', v_usuario
      from public.articulo a where a.id = p_articulo;
  end if;
  return v_linea;
end $$;

-- ---------------------------------------------------------------------
-- 3. Registrar pieza: emite el identificador único (P-04, P-05, P-06)
--    Idempotente: si la red falla y el teléfono reintenta con la misma
--    clave, devuelve la pieza ya creada en lugar de duplicarla.
-- ---------------------------------------------------------------------
create function public.registrar_pieza(
  p_linea uuid, p_cantidad numeric, p_clave_idempotencia uuid,
  p_peso_etiqueta_fabricante numeric default null, p_ubicacion uuid default null)
returns public.pieza
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_usuario uuid := privado.usuario_actual();
  v_linea public.recepcion_linea;
  v_rec public.recepcion;
  v_art public.articulo;
  v_emp public.empresa;
  v_n integer;
  v_codigo text;
  v_pieza public.pieza;
begin
  select * into v_linea from public.recepcion_linea where id = p_linea;
  if not found then raise exception 'La línea de recepción no existe' using errcode = '23503'; end if;

  -- Bloqueo compartido: varios operarios registran a la vez, pero nadie
  -- puede cerrar la recepción mientras se graba una pieza.
  select * into v_rec from public.recepcion where id = v_linea.recepcion_id for share;
  perform privado.exigir_permiso(v_rec.empresa_id, 'recepcion.registrar_pieza', v_rec.sucursal_id);

  select * into v_pieza from public.pieza
   where empresa_id = v_rec.empresa_id and clave_idempotencia = p_clave_idempotencia;
  if found then
    if v_pieza.linea_id <> p_linea then
      raise exception 'Clave de envío repetida para otra línea' using errcode = '23505';
    end if;
    return v_pieza;   -- reintento: misma pieza, mismo identificador
  end if;

  if v_rec.estado <> 'en_preparacion' then
    raise exception 'La recepción % ya no admite piezas (estado: %)', v_rec.numero, v_rec.estado;
  end if;
  if p_cantidad is null or p_cantidad <= 0 then
    raise exception 'La cantidad debe ser mayor que cero' using errcode = '22023';
  end if;
  if p_cantidad <> round(p_cantidad, 2) then
    raise exception 'La cantidad admite como máximo 2 decimales (P-08)' using errcode = '22023';
  end if;

  select * into v_art from public.articulo where id = v_linea.articulo_id;
  if v_art.cantidad_max_pieza is not null and p_cantidad > v_art.cantidad_max_pieza then
    raise exception 'El valor % % supera el máximo de % % configurado para %. Revisa la cifra.',
      p_cantidad, v_art.unidad_control, v_art.cantidad_max_pieza, v_art.unidad_control, v_art.codigo
      using errcode = '22023';
  end if;
  if p_ubicacion is not null and not exists (
       select 1 from public.ubicacion where id = p_ubicacion and almacen_id = v_rec.almacen_id) then
    raise exception 'La ubicación no pertenece al almacén de la recepción' using errcode = '23503';
  end if;

  -- Correlativo por empresa + fecha de recepción + abreviatura. La fila del
  -- contador queda bloqueada hasta el final de la transacción: dos operarios
  -- nunca obtienen el mismo número. Si algo falla, el número se pierde y no
  -- se reutiliza (queda como hueco).
  insert into public.contador_pieza (empresa_id, fecha, abreviatura, ultimo)
  values (v_rec.empresa_id, v_rec.fecha_recepcion, v_art.abreviatura, 1)
  on conflict (empresa_id, fecha, abreviatura) do update set ultimo = contador_pieza.ultimo + 1
  returning ultimo into v_n;

  select * into v_emp from public.empresa where id = v_rec.empresa_id;
  v_codigo := case when v_emp.usar_prefijo then v_emp.prefijo_codigo || '-' else '' end
              || to_char(v_rec.fecha_recepcion, 'YYYYMMDD') || '-' || v_art.abreviatura || '-'
              -- 001..999; desde 1000 crece a 4 dígitos (P-05). Ojo: lpad() recorta,
              -- por eso solo se rellena por debajo de 1000.
              || case when v_n < 1000 then lpad(v_n::text, 3, '0') else v_n::text end;

  update public.articulo set abreviatura_bloqueada = true where id = v_art.id and not abreviatura_bloqueada;

  insert into public.pieza (empresa_id, codigo, fecha_codigo, abreviatura, correlativo, articulo_id,
                            recepcion_id, linea_id, unidad, cantidad_inicial, cantidad_actual,
                            peso_etiqueta_fabricante, almacen_id, ubicacion_id, clave_idempotencia, creado_por)
  values (v_rec.empresa_id, v_codigo, v_rec.fecha_recepcion, v_art.abreviatura, v_n, v_art.id,
          v_rec.id, p_linea, v_art.unidad_control, p_cantidad, p_cantidad,
          p_peso_etiqueta_fabricante, v_rec.almacen_id, p_ubicacion, p_clave_idempotencia, v_usuario)
  returning * into v_pieza;

  perform privado.registrar_evento(v_rec.empresa_id, v_pieza.id, 'registrada', null, 'en_cuarentena',
    jsonb_build_object('cantidad', p_cantidad, 'unidad', v_art.unidad_control,
                       'peso_etiqueta_fabricante', p_peso_etiqueta_fabricante, 'recepcion', v_rec.numero));
  return v_pieza;
end $$;

-- ---------------------------------------------------------------------
-- Anular una pieza mal registrada (antes de la aprobación del gerente)
-- ---------------------------------------------------------------------
create function public.anular_pieza(p_pieza uuid, p_motivo text)
returns public.pieza
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_usuario uuid := privado.usuario_actual();
  v_pieza public.pieza;
  v_rec public.recepcion;
begin
  select * into v_pieza from public.pieza where id = p_pieza for update;
  if not found then raise exception 'La pieza no existe' using errcode = '23503'; end if;
  select * into v_rec from public.recepcion where id = v_pieza.recepcion_id for update;
  perform privado.exigir_permiso(v_pieza.empresa_id, 'recepcion.anular', v_rec.sucursal_id);
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Indica el motivo de la anulación'; end if;
  if v_rec.estado not in ('en_preparacion', 'pendiente_verificacion') then
    raise exception 'Tras enviar la recepción al gerente, las piezas ya no se anulan: se rechazan o se ajustan';
  end if;
  if v_pieza.estado not in ('en_cuarentena', 'pendiente_autorizacion') then
    raise exception 'La pieza % ya está %', v_pieza.codigo, v_pieza.estado;
  end if;

  perform privado.registrar_evento(v_pieza.empresa_id, p_pieza, 'anulada', v_pieza.estado, 'anulada', '{}', p_motivo);
  update public.pieza set estado = 'anulada' where id = p_pieza returning * into v_pieza;
  return v_pieza;
end $$;

-- ---------------------------------------------------------------------
-- Incidencias
-- ---------------------------------------------------------------------
create function public.registrar_incidencia(
  p_recepcion uuid, p_tipo text, p_descripcion text, p_pieza uuid default null)
returns public.incidencia
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_usuario uuid := privado.usuario_actual();
  v_rec public.recepcion;
  v_inc public.incidencia;
  v_antes public.estado_pieza;
begin
  select * into v_rec from public.recepcion where id = p_recepcion for update;
  if not found then raise exception 'La recepción no existe' using errcode = '23503'; end if;
  perform privado.exigir_permiso(v_rec.empresa_id, 'recepcion.registrar_pieza', v_rec.sucursal_id);
  if v_rec.estado in ('cerrada', 'rechazada', 'anulada') then
    raise exception 'La recepción % está % y no admite incidencias', v_rec.numero, v_rec.estado;
  end if;

  if p_pieza is not null then
    select estado into v_antes from public.pieza where id = p_pieza and recepcion_id = p_recepcion for update;
    if v_antes is null then raise exception 'La pieza no pertenece a esta recepción' using errcode = '23503'; end if;
    if v_antes <> 'en_cuarentena' then
      raise exception 'Solo se registran incidencias sobre piezas en cuarentena (estado: %)', v_antes;
    end if;
    update public.pieza set estado = 'pendiente_autorizacion' where id = p_pieza;
    perform privado.registrar_evento(v_rec.empresa_id, p_pieza, 'incidencia', v_antes, 'pendiente_autorizacion',
      jsonb_build_object('tipo', p_tipo), p_descripcion);
  end if;

  insert into public.incidencia (empresa_id, recepcion_id, pieza_id, tipo, descripcion, creado_por)
  values (v_rec.empresa_id, p_recepcion, p_pieza, p_tipo, p_descripcion, v_usuario)
  returning * into v_inc;
  return v_inc;
end $$;

-- Resolver: quien la registró no puede resolverla (P-11). Si se acepta, la
-- pieza vuelve a cuarentena y se libera con las demás; si no, se rechaza.
create function public.resolver_incidencia(p_incidencia uuid, p_aceptar_pieza boolean, p_resolucion text)
returns public.incidencia
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_usuario uuid := privado.usuario_actual();
  v_inc public.incidencia;
  v_rec public.recepcion;
  v_nuevo public.estado_pieza;
begin
  select * into v_inc from public.incidencia where id = p_incidencia for update;
  if not found then raise exception 'La incidencia no existe' using errcode = '23503'; end if;
  select * into v_rec from public.recepcion where id = v_inc.recepcion_id for update;
  perform privado.exigir_permiso(v_inc.empresa_id, 'pieza.resolver_incidencia', v_rec.sucursal_id);
  if not v_inc.abierta then raise exception 'La incidencia ya está resuelta'; end if;
  if v_inc.creado_por = v_usuario then
    raise exception 'Doble control: quien registra una incidencia no puede resolverla' using errcode = '42501';
  end if;
  if coalesce(trim(p_resolucion), '') = '' then raise exception 'Indica la resolución'; end if;

  if v_inc.pieza_id is not null then
    v_nuevo := case when p_aceptar_pieza then 'en_cuarentena' else 'rechazada' end;
    update public.pieza set estado = v_nuevo where id = v_inc.pieza_id and estado = 'pendiente_autorizacion';
    perform privado.registrar_evento(v_inc.empresa_id, v_inc.pieza_id, 'incidencia_resuelta',
      'pendiente_autorizacion', v_nuevo, jsonb_build_object('incidencia', p_incidencia), p_resolucion);
  end if;

  update public.incidencia
     set abierta = false, resolucion = p_resolucion, resuelto_por = v_usuario, resuelto_en = now()
   where id = p_incidencia returning * into v_inc;
  perform privado.intentar_cerrar(v_inc.recepcion_id);
  return v_inc;
end $$;

-- ---------------------------------------------------------------------
-- 5. Cerrar el registro de piezas  ·  6. Enviar al gerente
-- Ambos usan la versión de la recepción: si otra persona la cambió entre
-- tanto, la operación se rechaza con un aviso en vez de pisar su trabajo.
-- ---------------------------------------------------------------------
create function privado.bloquear_recepcion(p_recepcion uuid, p_version integer, p_permiso text)
returns public.recepcion
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rec public.recepcion;
begin
  select * into v_rec from public.recepcion where id = p_recepcion for update;
  if not found then raise exception 'La recepción no existe' using errcode = '23503'; end if;
  perform privado.exigir_permiso(v_rec.empresa_id, p_permiso, v_rec.sucursal_id);
  if p_version is distinct from v_rec.version then
    raise exception 'La recepción % cambió mientras la tenías abierta. Recarga para ver la versión actual.',
      v_rec.numero using errcode = '40001';
  end if;
  return v_rec;
end $$;

create function public.cerrar_registro(p_recepcion uuid, p_version integer)
returns public.recepcion
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rec public.recepcion;
begin
  perform privado.usuario_actual();
  v_rec := privado.bloquear_recepcion(p_recepcion, p_version, 'recepcion.verificar');
  if v_rec.estado <> 'en_preparacion' then
    raise exception 'Solo se cierra el registro de una recepción en preparación (estado: %)', v_rec.estado;
  end if;
  if not exists (select 1 from public.pieza where recepcion_id = p_recepcion and estado <> 'anulada') then
    raise exception 'La recepción no tiene piezas registradas';
  end if;
  update public.recepcion set estado = 'pendiente_verificacion', version = version + 1
   where id = p_recepcion returning * into v_rec;
  return v_rec;
end $$;

create function public.enviar_a_aprobacion(p_recepcion uuid, p_version integer)
returns public.recepcion
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_usuario uuid := privado.usuario_actual();
  v_rec public.recepcion;
begin
  v_rec := privado.bloquear_recepcion(p_recepcion, p_version, 'recepcion.verificar');
  if v_rec.estado <> 'pendiente_verificacion' then
    raise exception 'La recepción debe estar pendiente de verificación (estado: %)', v_rec.estado;
  end if;
  -- P-09: no hay tolerancia automática; toda recepción pasa por el gerente.
  update public.recepcion
     set estado = 'pendiente_autorizacion', verificado_por = v_usuario, verificado_en = now(), version = version + 1
   where id = p_recepcion returning * into v_rec;
  return v_rec;
end $$;

-- ---------------------------------------------------------------------
-- Cuadre de recepción (P-09): facturado frente a recibido, por artículo
-- ---------------------------------------------------------------------
create view public.vista_cuadre_recepcion with (security_invoker = true) as
select
  l.empresa_id,
  l.recepcion_id,
  l.id                                             as linea_id,
  a.codigo                                         as articulo_codigo,
  a.descripcion                                    as articulo_descripcion,
  a.unidad_control                                 as unidad,
  l.cantidad_esperada,
  coalesce(sum(p.cantidad_inicial) filter (where p.estado <> 'anulada'), 0)       as cantidad_recibida,
  coalesce(sum(p.cantidad_inicial) filter (where p.estado <> 'anulada'), 0)
    - coalesce(l.cantidad_esperada, 0)                                            as diferencia,
  case when l.cantidad_esperada > 0 then round(
    (coalesce(sum(p.cantidad_inicial) filter (where p.estado <> 'anulada'), 0) - l.cantidad_esperada)
    * 100 / l.cantidad_esperada, 2) end                                            as diferencia_pct,
  l.piezas_esperadas,
  count(p.id) filter (where p.estado <> 'anulada')                                 as piezas_registradas,
  count(p.id) filter (where p.estado = 'anulada')                                  as piezas_anuladas,
  count(p.id) filter (where p.estado = 'pendiente_autorizacion')                   as piezas_con_incidencia
from public.recepcion_linea l
join public.articulo a on a.id = l.articulo_id
left join public.pieza p on p.linea_id = l.id
group by l.id, a.id;

grant select on public.vista_cuadre_recepcion to authenticated;

create function public.cuadre_recepcion(p_recepcion uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rec public.recepcion; v jsonb;
begin
  select * into v_rec from public.recepcion where id = p_recepcion;
  if not found then raise exception 'La recepción no existe' using errcode = '23503'; end if;
  perform privado.exigir_permiso(v_rec.empresa_id, 'recepcion.ver', v_rec.sucursal_id);
  select jsonb_build_object(
    'recepcion', v_rec.numero,
    'documento', v_rec.documento_tipo || ' ' || v_rec.documento_numero,
    'fecha_recepcion', v_rec.fecha_recepcion,
    'lineas', coalesce(jsonb_agg(to_jsonb(c) - 'empresa_id' - 'recepcion_id' order by c.articulo_codigo), '[]'::jsonb),
    'hay_diferencias', coalesce(bool_or(c.diferencia <> 0 or c.cantidad_esperada is null
                                        or (c.piezas_esperadas is not null and c.piezas_esperadas <> c.piezas_registradas)), false),
    'incidencias_abiertas', (select count(*) from public.incidencia i where i.recepcion_id = p_recepcion and i.abierta))
  into v
  from public.vista_cuadre_recepcion c where c.recepcion_id = p_recepcion;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- 7. Decisión del gerente. Doble control (P-11): quien envió la recepción
--    a aprobación no puede aprobarla.
-- ---------------------------------------------------------------------
create function public.decidir_recepcion(p_recepcion uuid, p_version integer, p_decision text, p_motivo text default null)
returns public.recepcion
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_usuario uuid := privado.usuario_actual();
  v_rec public.recepcion;
  v_cuadre jsonb;
  p record;
begin
  v_rec := privado.bloquear_recepcion(p_recepcion, p_version, 'recepcion.aprobar');
  if v_rec.estado <> 'pendiente_autorizacion' then
    raise exception 'La recepción no está pendiente de autorización (estado: %)', v_rec.estado;
  end if;
  if p_decision not in ('aprobada', 'rechazada') then raise exception 'Decisión no válida'; end if;
  if v_rec.verificado_por = v_usuario then
    raise exception 'Doble control: quien envió la recepción a aprobación no puede aprobarla' using errcode = '42501';
  end if;

  v_cuadre := public.cuadre_recepcion(p_recepcion);
  if (p_decision = 'rechazada' or (v_cuadre ->> 'hay_diferencias')::boolean)
     and coalesce(trim(p_motivo), '') = '' then
    raise exception 'Hay diferencias en el cuadre o se rechaza la recepción: indica el motivo';
  end if;

  insert into public.aprobacion_recepcion (empresa_id, recepcion_id, decision, motivo, cuadre, aprobado_por)
  values (v_rec.empresa_id, p_recepcion, p_decision, p_motivo, v_cuadre, v_usuario);

  if p_decision = 'aprobada' then
    for p in select * from public.pieza where recepcion_id = p_recepcion and estado = 'en_cuarentena' loop
      perform privado.registrar_evento(p.empresa_id, p.id, 'aprobada_en_recepcion', p.estado, p.estado, '{}', p_motivo);
    end loop;
    update public.recepcion set estado = 'verificada', version = version + 1
     where id = p_recepcion returning * into v_rec;
  else
    for p in select * from public.pieza where recepcion_id = p_recepcion
                                           and estado in ('en_cuarentena', 'pendiente_autorizacion') loop
      update public.pieza set estado = 'rechazada' where id = p.id;
      perform privado.registrar_evento(p.empresa_id, p.id, 'rechazada', p.estado, 'rechazada', '{}', p_motivo);
    end loop;
    update public.recepcion set estado = 'rechazada', version = version + 1
     where id = p_recepcion returning * into v_rec;
  end if;
  return v_rec;
end $$;

-- ---------------------------------------------------------------------
-- 8. Liberar (P-10: siempre una persona autorizada, nunca automático)
-- ---------------------------------------------------------------------
create function public.liberar_piezas(p_recepcion uuid, p_piezas uuid[] default null)
returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_usuario uuid := privado.usuario_actual();
  v_rec public.recepcion;
  v_total integer := 0;
  p record;
begin
  select * into v_rec from public.recepcion where id = p_recepcion for update;
  if not found then raise exception 'La recepción no existe' using errcode = '23503'; end if;
  perform privado.exigir_permiso(v_rec.empresa_id, 'pieza.liberar', v_rec.sucursal_id);
  if v_rec.estado <> 'verificada' then
    raise exception 'Solo se liberan piezas de una recepción aprobada por el gerente (estado: %)', v_rec.estado;
  end if;

  for p in select * from public.pieza
            where recepcion_id = p_recepcion and estado = 'en_cuarentena'
              and (p_piezas is null or id = any (p_piezas))
            for update loop
    update public.pieza set estado = 'liberada' where id = p.id;
    perform privado.registrar_evento(p.empresa_id, p.id, 'liberada', 'en_cuarentena', 'liberada');
    v_total := v_total + 1;
  end loop;

  perform privado.intentar_cerrar(p_recepcion);
  return v_total;
end $$;

-- ---------------------------------------------------------------------
-- Anular una recepción completa (con motivo; sus identificadores quedan quemados)
-- ---------------------------------------------------------------------
create function public.anular_recepcion(p_recepcion uuid, p_version integer, p_motivo text)
returns public.recepcion
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_rec public.recepcion;
  p record;
begin
  perform privado.usuario_actual();
  v_rec := privado.bloquear_recepcion(p_recepcion, p_version, 'recepcion.anular');
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Indica el motivo de la anulación'; end if;
  if v_rec.estado not in ('en_preparacion', 'pendiente_verificacion', 'pendiente_autorizacion') then
    raise exception 'Una recepción % no puede anularse', v_rec.estado;
  end if;
  for p in select * from public.pieza where recepcion_id = p_recepcion
                                         and estado in ('en_cuarentena', 'pendiente_autorizacion') loop
    update public.pieza set estado = 'anulada' where id = p.id;
    perform privado.registrar_evento(p.empresa_id, p.id, 'anulada', p.estado, 'anulada', '{}', p_motivo);
  end loop;
  update public.recepcion set estado = 'anulada', observaciones = coalesce(observaciones || E'\n', '') || 'Anulada: ' || p_motivo,
         version = version + 1
   where id = p_recepcion returning * into v_rec;
  return v_rec;
end $$;

-- ---------------------------------------------------------------------
-- Etiquetas y QR (P-14, P-16)
-- ---------------------------------------------------------------------
create function public.registrar_impresion_etiqueta(p_pieza uuid) returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_usuario uuid := privado.usuario_actual();
  v_pieza public.pieza;
  v_n integer;
begin
  select * into v_pieza from public.pieza where id = p_pieza for update;
  if not found then raise exception 'La pieza no existe' using errcode = '23503'; end if;
  perform privado.exigir_permiso(v_pieza.empresa_id, 'etiqueta.imprimir', privado.sucursal_de_almacen(v_pieza.almacen_id));
  if v_pieza.estado in ('anulada', 'rechazada') then
    raise exception 'La pieza % está %: no se imprimen etiquetas', v_pieza.codigo, v_pieza.estado;
  end if;
  select coalesce(max(numero_impresion), 0) + 1 into v_n from public.etiqueta_impresion where pieza_id = p_pieza;
  insert into public.etiqueta_impresion (empresa_id, pieza_id, numero_impresion, usuario_id)
  values (v_pieza.empresa_id, p_pieza, v_n, v_usuario);
  perform privado.registrar_evento(v_pieza.empresa_id, p_pieza, 'etiqueta_impresa', v_pieza.estado, v_pieza.estado,
    jsonb_build_object('impresion', v_n));
  return v_n;
end $$;

-- P-16: el QR es la cédula del rollo. Texto legible por cualquier teléfono,
-- sin internet; la primera línea es el identificador, que la app usa para
-- abrir la ficha y, en picking o venta, seleccionar exactamente esta pieza.
create function public.contenido_qr(p_pieza uuid) returns text
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare r record;
begin
  select p.*, a.codigo as art_codigo, a.descripcion as art_descripcion
    into r from public.pieza p join public.articulo a on a.id = p.articulo_id where p.id = p_pieza;
  if not found then raise exception 'La pieza no existe' using errcode = '23503'; end if;
  perform privado.exigir_permiso(r.empresa_id, 'recepcion.ver', privado.sucursal_de_almacen(r.almacen_id));
  return r.codigo || E'\n'
      || r.art_codigo || ' ' || r.art_descripcion || E'\n'
      || 'Peso neto: ' || replace(to_char(r.cantidad_inicial, 'FM999999990.00'), '.', ',') || ' ' || r.unidad || E'\n'
      || 'Recibido: ' || to_char(r.fecha_codigo, 'DD/MM/YYYY');
end $$;

-- ---------------------------------------------------------------------
-- Permisos de ejecución: solo usuarios autenticados, nunca anónimos
-- ---------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon;
grant execute on function
  public.crear_empresa(text, text, uuid),
  public.crear_recepcion(uuid, uuid, text, text, date, uuid, text),
  public.agregar_linea_recepcion(uuid, uuid, numeric, integer),
  public.registrar_pieza(uuid, numeric, uuid, numeric, uuid),
  public.anular_pieza(uuid, text),
  public.registrar_incidencia(uuid, text, text, uuid),
  public.resolver_incidencia(uuid, boolean, text),
  public.cerrar_registro(uuid, integer),
  public.enviar_a_aprobacion(uuid, integer),
  public.cuadre_recepcion(uuid),
  public.decidir_recepcion(uuid, integer, text, text),
  public.liberar_piezas(uuid, uuid[]),
  public.anular_recepcion(uuid, integer, text),
  public.registrar_impresion_etiqueta(uuid),
  public.contenido_qr(uuid)
to authenticated;
