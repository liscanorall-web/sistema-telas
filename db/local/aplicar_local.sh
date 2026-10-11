#!/bin/bash
# Recrea la base local "telas" y aplica el stub de Supabase + todas las migraciones
set -e
DB=${1:-telas}
cd /mnt/project-files/sistema-telas/db
su postgres -c "dropdb --if-exists $DB && createdb $DB"
for f in local/00_supabase_stub.sql migrations/*.sql; do
  su postgres -c "psql -q -v ON_ERROR_STOP=1 -d $DB -f '$f'" || { echo "FALLO en $f"; exit 1; }
done
echo "OK: migraciones aplicadas"
