# Despliegue de Grafana en MicroK8s con Helm

Tiempo estimado: 45 a 60 minutos, de los cuales unos 15 son espera.

---

## Qué se orquesta y qué no

Conviene tenerlo claro antes de empezar, porque es una pregunta probable en la sustentación.

Lambda y RDS son servicios administrados de AWS: no se pueden meter dentro de un clúster de Kubernetes, y no tiene sentido intentarlo. Lo que se orquesta en MicroK8s es la **capa de visualización**: Grafana pasa de ser un contenedor suelto lanzado con `docker run` a ser un *release* de Helm con su Deployment, su Service, sus Secrets y su ConfigMap, gestionado por el clúster.

Esa es la lectura correcta del enunciado: el pipeline sigue siendo el mismo de extremo a extremo, y Kubernetes entra como plano de orquestación del único componente que ustedes operan directamente.

---

## Paso 1 — Instancia EC2

En la consola de EC2, **Lanzar instancias**:

| Campo | Valor |
|---|---|
| Nombre | `microk8s-grafana` |
| AMI | **Ubuntu Server 24.04 LTS** |
| Tipo | **t3.medium** (MicroK8s necesita 2 vCPU y 4 GB) |
| Par de claves | el que ya tengan |
| Almacenamiento | **20 GB** (MicroK8s con sus imágenes no cabe en 8 GB) |
| Perfil IAM | `LabInstanceProfile` |

En **Configuración de red → Editar**, elijan el **mismo grupo de seguridad** que usa la base RDS. Eso resuelve la conectividad sin reglas adicionales, porque ese grupo ya se permite a sí mismo en el puerto 5432.

Luego agreguen dos reglas de entrada a ese grupo:

| Tipo | Puerto | Origen | Para qué |
|---|---|---|---|
| SSH | 22 | Mi IP | Instalación |
| Custom TCP | **30000** | 0.0.0.0/0 | Acceso al dashboard |

---

## Paso 2 — Subir los archivos

Conéctense por SSH y copien los tres archivos de esta carpeta:

```bash
ssh -o ServerAliveInterval=60 -i llave.pem ubuntu@IP_PUBLICA
mkdir -p ~/microk8s && cd ~/microk8s
```

Desde su equipo, en otra terminal:

```powershell
scp -i llave.pem desplegar-microk8s.sh values.yaml cafeterias.json ubuntu@IP_PUBLICA:~/microk8s/
```

---

## Paso 3 — Ejecutar

```bash
cd ~/microk8s
sudo bash desplegar-microk8s.sh
```

Pedirá por teclado el endpoint de RDS, el nombre de la base, la contraseña de `grafana_reader` y una contraseña de administrador para Grafana. Ninguna queda escrita en disco ni en el repositorio: se guardan como Secrets de Kubernetes.

El script instala MicroK8s, habilita `dns`, `hostpath-storage` y `helm3`, crea el namespace `observabilidad`, carga los Secrets y el dashboard como ConfigMap, y despliega Grafana con Helm.

Al terminar imprime la URL: `http://IP_PUBLICA:30000`

---

## Paso 4 — Evidencias para el informe y el video

Capturen la salida de estos cuatro comandos. Son los que demuestran que hay un clúster real y un release de Helm, no un contenedor suelto:

```bash
sudo microk8s kubectl get nodes
sudo microk8s kubectl -n observabilidad get pods,svc
sudo microk8s helm3 -n observabilidad list
sudo microk8s kubectl -n observabilidad describe deploy grafana | head -30
```

Y una captura del dashboard abierto en `http://IP_PUBLICA:30000`, que es la prueba de que el pipeline funciona de extremo a extremo: RDS responde a través de la fuente de datos provisionada por Helm.

---

## Paso 5 — Apagado (FinOps, obligatorio)

```bash
sudo microk8s helm3 -n observabilidad uninstall grafana
```

Y desde la consola de EC2, **Terminar** la instancia. Capturen el estado `Terminated`.

---

## Si algo falla

**El pod se queda en `Pending`.** Falta capacidad o almacenamiento. Verifiquen con `sudo microk8s kubectl -n observabilidad describe pod <nombre>`; si menciona `Insufficient cpu` o `memory`, la instancia es más pequeña que t3.medium.

**El pod arranca pero el dashboard muestra error en los paneles.** Es la conexión a RDS. Revisen los logs:

```bash
sudo microk8s kubectl -n observabilidad logs deploy/grafana -c grafana --tail=40
```

Si dice `connection refused` o `timeout`, el grupo de seguridad de RDS no permite el 5432 desde esta instancia. Si dice `password authentication failed`, la contraseña de `grafana_reader` es incorrecta: borren el Secret y vuelvan a ejecutar el script.

**No carga la página en el puerto 30000.** Falta la regla de entrada en el grupo de seguridad, o la IP pública cambió tras reiniciar la instancia.

**El dashboard aparece vacío o sin paneles.** El ConfigMap no se montó. Verifiquen con `sudo microk8s kubectl -n observabilidad get configmap grafana-dashboard-cafeterias -o yaml | head -20`.

---

## Qué cambia en el informe

Si completan este despliegue, hay que reescribir la subsección 4 ("Sobre la orquestación con Kubernetes"), que hoy argumenta por qué *no* se usó un orquestador, y actualizar el diagrama y la tabla de costos: t3.medium cuesta 0,0416 USD/hora, el doble de la t3.small, lo que lleva el total mensual de 31,26 a unos 46 USD.

Mándenme las capturas del paso 4 y yo ajusto ambas cosas.
