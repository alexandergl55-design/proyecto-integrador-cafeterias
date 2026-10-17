#!/usr/bin/env bash
# =====================================================================
# preparar-rds.sh
# Recrea la base de datos del proyecto en Amazon RDS: crea la base,
# la tabla, carga las 46 cafeterías y crea el usuario de solo lectura
# que usará Grafana.
#
# Se ejecuta en la EC2 de MicroK8s, ANTES de desplegar-microk8s.sh.
#
# Uso:
#   sudo bash preparar-rds.sh
#
# Requisitos:
#   - La instancia RDS existe y está disponible.
#   - El grupo de seguridad de RDS permite el 5432 desde esta EC2.
# =====================================================================
set -euo pipefail

REPO_URL="https://github.com/christian130994-coder/grafana-cafeterias-teusaquillo_"
REPO_DIR="/opt/cafeterias-sql"

paso()  { echo; echo "==> $*"; }
falla() { echo; echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || falla "Ejecuta con sudo: sudo bash preparar-rds.sh"

# ---------------------------------------------------------------------
# 0. Datos de conexión
# ---------------------------------------------------------------------
echo "Datos de la base RDS (consola de Amazon RDS)."
read -rp "Endpoint de RDS (sin :5432): " RDS_ENDPOINT
RDS_ENDPOINT="${RDS_ENDPOINT// /}"; RDS_ENDPOINT="${RDS_ENDPOINT%:5432}"
[ -n "$RDS_ENDPOINT" ] || falla "El endpoint no puede estar vacío."

read -rp "Usuario administrador de RDS [postgres]: " RDS_USER
RDS_USER="${RDS_USER:-postgres}"
read -rsp "Contraseña del administrador de RDS: " RDS_PASSWORD; echo
read -rp "Nombre de la base de datos a crear [cafeterias]: " RDS_DB
RDS_DB="${RDS_DB:-cafeterias}"

while true; do
  read -rsp "Crea una contraseña para el usuario grafana_reader (mínimo 8 caracteres): " GR_PASS; echo
  [ "${#GR_PASS}" -ge 8 ] && break
  echo "Muy corta, intenta de nuevo."
done

# ---------------------------------------------------------------------
# 1. Herramientas
# ---------------------------------------------------------------------
paso "Instalando git y el cliente de PostgreSQL"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git postgresql-client >/dev/null

# ---------------------------------------------------------------------
# 2. Scripts SQL y CSV del repositorio del equipo
# ---------------------------------------------------------------------
paso "Descargando los scripts SQL y el CSV de las 46 cafeterías"
rm -rf "$REPO_DIR"
git clone --depth 1 "$REPO_URL" "$REPO_DIR" >/dev/null 2>&1 \
  || falla "No se pudo clonar $REPO_URL"
cd "$REPO_DIR"

for f in 01_ddl.sql 02_carga.sql 03_usuario_lectura.sql cafeterias_teusaquillo_limpio.csv; do
  [ -f "$f" ] || falla "Falta $f en el repositorio."
done

export PGHOST="$RDS_ENDPOINT" PGPORT=5432 PGUSER="$RDS_USER" \
       PGPASSWORD="$RDS_PASSWORD" PGSSLMODE=require PGCONNECT_TIMEOUT=10

# ---------------------------------------------------------------------
# 3. Conexión
# ---------------------------------------------------------------------
paso "Probando la conexión con RDS"
if ! psql -d postgres -tAc "SELECT 1" >/dev/null 2>/tmp/rds_error.txt; then
  cat /tmp/rds_error.txt
  falla "No hay conexión con RDS. Revisa que la base esté disponible y que
  su grupo de seguridad permita el puerto 5432 desde esta instancia."
fi
echo "Conexión OK."

# ---------------------------------------------------------------------
# 4. Base, tabla, datos y usuario de lectura
# ---------------------------------------------------------------------
paso "Creando la base '$RDS_DB' si no existe"
if [ "$(psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$RDS_DB'")" != "1" ]; then
  psql -d postgres -v ON_ERROR_STOP=1 -qc "CREATE DATABASE \"$RDS_DB\""
fi
export PGDATABASE="$RDS_DB"

paso "Creando la tabla (DDL de la Actividad 3)"
psql -v ON_ERROR_STOP=1 -q -f 01_ddl.sql

paso "Cargando las 46 cafeterías (UPSERT idempotente)"
psql -v ON_ERROR_STOP=1 -q -f 02_carga.sql

paso "Creando el usuario grafana_reader (solo SELECT)"
psql -v ON_ERROR_STOP=1 -q -v clave="$GR_PASS" -v bd="$RDS_DB" -f 03_usuario_lectura.sql

# ---------------------------------------------------------------------
# 5. Verificación
# ---------------------------------------------------------------------
paso "Verificando la carga"
psql -c "SELECT COUNT(*) AS total_registros,
                COUNT(DISTINCT fsq_place_id) AS ids_unicos
         FROM cafeterias_teusaquillo;"

cat <<FIN

=====================================================================
Base lista.

  Endpoint : $RDS_ENDPOINT
  Base     : $RDS_DB
  Usuario de Grafana : grafana_reader

Guarda la contraseña de grafana_reader: la pedirá el siguiente script.

Siguiente paso:
  sudo bash desplegar-microk8s.sh
=====================================================================
FIN
