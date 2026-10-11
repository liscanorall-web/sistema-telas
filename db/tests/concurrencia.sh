#!/bin/bash
# Prueba de concurrencia: 4 operarios registran 25 piezas cada uno, a la vez,
# en la misma línea de la misma recepción. Se espera: 100 piezas, 100 códigos
# distintos y correlativos 1..100 sin huecos ni repetidos.
# Requiere una base ya preparada por pruebas_fase2.sql.
set -e
DB=${1:-telas}
PSQL="psql -X -q -t -A -d $DB"
RECEP=00000000-0000-0000-0000-0000000000a3
EMP=$(su postgres -c "$PSQL -c \"select id from empresa where nombre='Textiles A'\"")
ALM=$(su postgres -c "$PSQL -c \"select id from almacen where codigo='ALM-N' and empresa_id='$EMP'\"")
PROV=$(su postgres -c "$PSQL -c \"select id from proveedor where codigo='PROV1' and empresa_id='$EMP'\"")
ART=$(su postgres -c "$PSQL -c \"select id from articulo where codigo='MUTJ001' and empresa_id='$EMP'\"")
LIN=$(su postgres -c "$PSQL" <<SQL
set role authenticated; select prueba.como('$RECEP');
select (public.agregar_linea_recepcion(
  (public.crear_recepcion('$EMP','$PROV','factura','F-CONC','2026-10-20','$ALM')).id, '$ART', 2500, 100)).id;
SQL
)
LIN=$(echo "$LIN" | tail -1)
SQLF=$(mktemp)
{ echo "set role authenticated; select prueba.como('$RECEP');"
  for i in $(seq 1 25); do echo "select (public.registrar_pieza('$LIN', round((20 + random()*10)::numeric, 2), gen_random_uuid())).codigo;"; done
} > "$SQLF"
chmod 644 "$SQLF"
for w in 1 2 3 4; do su postgres -c "$PSQL -f $SQLF" > /dev/null & done
wait
su postgres -c "$PSQL" <<SQL
select 'piezas=' || count(*) || ' codigos_distintos=' || count(distinct codigo)
    || ' correlativo_min=' || min(correlativo) || ' correlativo_max=' || max(correlativo)
  from pieza where linea_id = '$LIN';
SQL
rm -f "$SQLF"
