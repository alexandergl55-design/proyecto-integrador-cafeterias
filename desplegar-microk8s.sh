#!/usr/bin/env bash
# =====================================================================
# desplegar-microk8s.sh
# Despliega Grafana sobre un clúster MicroK8s mediante Helm, conectado
# a Amazon RDS PostgreSQL.
#
# Uso, en una EC2 t3.medium con Ubuntu 24.04:
#   sudo bash desplegar-microk8s.sh
#
# Requisitos previos:
#   - La instancia RDS cafeterias-db existe y está disponible.
#   - El grupo de seguridad de RDS permite el puerto 5432 desde el
#     grupo de seguridad de esta EC2.
#   - El grupo de seguridad de esta EC2 permite el puerto 30000 (y el
#     22 mientras dure la instalación).
#   - En esta carpeta están values.yaml y cafeterias.json.
#
# Las credenciales se piden por teclado y se guardan como Secrets de
# Kubernetes; nunca quedan en el repositorio.
# =====================================================================
set -euo pipefail

NS=observabilidad
DIR="$(cd "$(dirname "$0")" && pwd)"

paso()  { echo; echo "==> $*"; }
falla() { echo; echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || falla "Ejecuta con sudo: sudo bash desplegar-microk8s.sh"
[ -f "$DIR/values.yaml" ]      || falla "No encuentro values.yaml en $DIR"
[ -f "$DIR/cafeterias.json" ]  || falla "No encuentro cafeterias.json en $DIR"

# ---------------------------------------------------------------------
# 0. Datos de conexión
# ---------------------------------------------------------------------
echo "Datos de la base RDS (los encuentras en la consola de Amazon RDS)."
read -rp "Endpoint de RDS (sin :5432): " RDS_ENDPOINT
RDS_ENDPOINT="${RDS_ENDPOINT// /}"; RDS_ENDPOINT="${RDS_ENDPOINT%:5432}"
[ -n "$RDS_ENDPOINT" ] || falla "El endpoint no puede estar vacío."

read -rp "Nombre de la base de datos [cafeterias]: " RDS_DB
RDS_DB="${RDS_DB:-cafeterias}"

read -rsp "Contraseña del usuario grafana_reader: " GRAFANA_DB_PASSWORD; echo
[ -n "$GRAFANA_DB_PASSWORD" ] || falla "La contraseña no puede estar vacía."

while true; do
  read -rsp "Contraseña de administrador para Grafana (mínimo 8 caracteres): " GF_ADMIN; echo
  [ "${#GF_ADMIN}" -ge 8 ] && break
  echo "Muy corta, intenta de nuevo."
done

# ---------------------------------------------------------------------
# 1. Instalación de MicroK8s
# ---------------------------------------------------------------------
paso "Instalando MicroK8s (3 a 5 minutos)"
if ! snap list microk8s >/dev/null 2>&1; then
  snap install microk8s --classic --channel=1.31/stable
fi

paso "Esperando a que el clúster esté listo"
microk8s status --wait-ready >/dev/null

paso "Habilitando complementos: dns, hostpath-storage, helm3"
microk8s enable dns >/dev/null
microk8s enable hostpath-storage >/dev/null
microk8s enable helm3 >/dev/null
microk8s status --wait-ready >/dev/null

# Permite usar kubectl y helm sin el prefijo microk8s
snap alias microk8s.kubectl kubectl >/dev/null 2>&1 || true
snap alias microk8s.helm3 helm      >/dev/null 2>&1 || true

echo "Nodo del clúster:"
microk8s kubectl get nodes

# ---------------------------------------------------------------------
# 2. Namespace y Secrets
# ---------------------------------------------------------------------
paso "Creando el namespace '$NS'"
microk8s kubectl create namespace "$NS" --dry-run=client -o yaml \
  | microk8s kubectl apply -f - >/dev/null

paso "Guardando las credenciales como Secrets de Kubernetes"
microk8s kubectl -n "$NS" create secret generic rds-credenciales \
  --from-literal=endpoint="$RDS_ENDPOINT" \
  --from-literal=database="$RDS_DB" \
  --from-literal=password="$GRAFANA_DB_PASSWORD" \
  --dry-run=client -o yaml | microk8s kubectl apply -f - >/dev/null

microk8s kubectl -n "$NS" create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$GF_ADMIN" \
  --dry-run=client -o yaml | microk8s kubectl apply -f - >/dev/null

echo "Secrets creados (los valores quedan cifrados en el almacén del clúster):"
microk8s kubectl -n "$NS" get secrets

# ---------------------------------------------------------------------
# 3. Dashboard como ConfigMap
# ---------------------------------------------------------------------
paso "Cargando el dashboard de 9 paneles como ConfigMap"
microk8s kubectl -n "$NS" create configmap grafana-dashboard-cafeterias \
  --from-file=cafeterias.json="$DIR/cafeterias.json" \
  --dry-run=client -o yaml | microk8s kubectl apply -f - >/dev/null

# ---------------------------------------------------------------------
# 4. Despliegue con Helm
# ---------------------------------------------------------------------
paso "Agregando el repositorio oficial de Grafana"
microk8s helm3 repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
microk8s helm3 repo update >/dev/null

paso "Desplegando Grafana con Helm (3 a 5 minutos)"
microk8s helm3 upgrade --install grafana grafana/grafana \
  --namespace "$NS" \
  --values "$DIR/values.yaml" \
  --wait --timeout 10m

# ---------------------------------------------------------------------
# 5. Verificación
# ---------------------------------------------------------------------
paso "Estado del despliegue"
microk8s helm3 -n "$NS" list
echo
microk8s kubectl -n "$NS" get pods -o wide
echo
microk8s kubectl -n "$NS" get svc

IP_PUBLICA="$(curl -s --max-time 5 http://169.254.169.254/latest/meta-data/public-ipv4 || echo '<IP-PUBLICA>')"

cat <<FIN

=====================================================================
Despliegue terminado.

  Dashboard:  http://${IP_PUBLICA}:30000
  Acceso:     visor anónimo de solo lectura (no pide credenciales)
  Edición:    botón 'Sign in', usuario admin

Evidencias para el informe y el video:
  microk8s kubectl -n $NS get pods
  microk8s kubectl -n $NS get svc
  microk8s helm3 -n $NS list
  microk8s kubectl -n $NS logs deploy/grafana -c grafana --tail=20

Al terminar, por gobernanza FinOps:
  microk8s helm3 -n $NS uninstall grafana
  y termina la instancia EC2 desde la consola.
=====================================================================
FIN
