# Guion de la sesión final

Todo en una sola sesión del Learner Lab. Tiempo total: entre 2 y 2 horas y media, incluida la grabación del video.

**El orden importa.** Graben el video mientras la infraestructura está arriba; si lo dejan para después, les tocará levantar todo otra vez.

---

## Antes de encender el laboratorio (10 min)

Tengan a mano en su equipo, en una carpeta:

- `preparar-rds.sh`
- `desplegar-microk8s.sh`
- `values.yaml`
- `cafeterias.json`
- La llave `.pem` que vayan a usar

Y decidan de antemano dos contraseñas, porque los scripts las piden:

- La del administrador de RDS
- La de `grafana_reader` (mínimo 8 caracteres)

Escríbanlas en un papel. Las van a necesitar en tres momentos distintos y perder el hilo ahí cuesta tiempo.

---

## Fase 1 — Base de datos (25 min, de los cuales 10 son espera)

**1.1** En AWS Academy, **Start Lab**. Esperen el punto verde.

**1.2** Consola → **RDS** → **Crear base de datos** → Creación estándar:

| Campo | Valor |
|---|---|
| Motor | PostgreSQL |
| Plantilla | Free tier |
| Identificador | `cafeterias-db` |
| Usuario maestro | `postgres` |
| Contraseña | la que decidieron |
| Clase | db.t3.micro |
| Almacenamiento | 20 GB gp3, sin escalado automático |
| Acceso público | **No** |
| Copias de seguridad | Desactivar |

**No habiliten acceso público.** En la Actividad 3 tuvieron que activarlo porque se conectaban desde DBeaver en su equipo; aquí la conexión viene desde la EC2, dentro de la misma VPC, así que no hace falta y es más seguro.

**1.3** Mientras se crea (de 5 a 10 minutos), pasen a la Fase 2. Vuelvan cuando el estado sea **Available** y copien el **endpoint**.

---

## Fase 2 — Instancia EC2 (15 min)

**2.1** Consola → **EC2** → **Lanzar instancias**:

| Campo | Valor |
|---|---|
| Nombre | `microk8s-grafana` |
| AMI | **Ubuntu Server 24.04 LTS** |
| Tipo | **t3.medium** |
| Par de claves | la suya |
| Almacenamiento | **20 GB** |

**2.2** En **Configuración de red → Editar**, elijan **Seleccionar grupo de seguridad existente** y marquen el mismo grupo donde quedó la base RDS (normalmente `default`).

Eso resuelve la conectividad: ese grupo ya se permite a sí mismo, así que la EC2 alcanza el 5432 de RDS sin reglas nuevas.

**2.3** En **Detalles avanzados**, perfil de IAM: **LabInstanceProfile**.

**2.4** Lancen la instancia.

**2.5** Mientras arranca, vayan a **EC2 → Grupos de seguridad**, abran el grupo que eligieron, **Editar reglas de entrada** y agreguen dos reglas nuevas (sin tocar las existentes):

| Tipo | Puerto | Origen |
|---|---|---|
| SSH | 22 | Mi IP |
| Custom TCP | **30000** | Anywhere-IPv4 |

**2.6** Cuando la instancia esté en *running* y pase las verificaciones, copien su **IP pública**.

---

## Fase 3 — Preparar la base (15 min)

**3.1** Desde PowerShell, en la carpeta donde están los archivos:

```powershell
scp -i llave.pem preparar-rds.sh desplegar-microk8s.sh values.yaml cafeterias.json ubuntu@IP_PUBLICA:~/
```

**3.2** Conéctense:

```powershell
ssh -o ServerAliveInterval=60 -i llave.pem ubuntu@IP_PUBLICA
```

El usuario es **ubuntu**, no `ec2-user`: la AMI es Ubuntu.

**3.3** Ejecuten:

```bash
sudo bash preparar-rds.sh
```

Pedirá el endpoint de RDS, el usuario y contraseña de administrador, el nombre de la base y una contraseña nueva para `grafana_reader`.

Al terminar imprime el conteo. **Debe decir 46 registros y 46 ids únicos.** Esa salida es evidencia: cápturenla.

---

## Fase 4 — MicroK8s y Grafana (30 min, casi todo espera)

**4.1**

```bash
sudo bash desplegar-microk8s.sh
```

Pedirá de nuevo el endpoint, el nombre de la base, la contraseña de `grafana_reader` y una contraseña de administrador para Grafana.

Instala MicroK8s, habilita los complementos, crea los Secrets y el ConfigMap del dashboard, y despliega Grafana con Helm. Entre 10 y 15 minutos.

**4.2** Al terminar imprime la URL. Ábranla en el navegador:

```
http://IP_PUBLICA:30000
```

Deben ver el dashboard con los nueve paneles y datos reales. Si los paneles muestran error, revisen la sección de diagnóstico de `PASOS.md`.

---

## Fase 5 — Evidencias (10 min)

Capturen la salida de estos comandos. Son los que prueban que hay un clúster y un release de Helm, no un contenedor suelto:

```bash
sudo microk8s kubectl get nodes
sudo microk8s kubectl -n observabilidad get pods,svc
sudo microk8s helm3 -n observabilidad list
sudo microk8s kubectl -n observabilidad get secrets,configmaps
```

Más una captura del dashboard abierto en el navegador, con la URL visible en la barra de direcciones.

---

## Fase 6 — Video (30 a 40 min)

Graben ahora, con todo funcionando. Cinco a siete minutos, en este orden:

1. **Pipeline funcionando** (2 min). Muestren el bucket de S3 con el CSV, la función Lambda y su log de CloudWatch, la consulta `SELECT COUNT(*)` devolviendo 46, y el dashboard en vivo. La cadena completa.
2. **Decisiones arquitectónicas** (1.5 min). Apóyense en el diagrama: por qué serverless para la transformación, por qué PostgreSQL y no DynamoDB, por qué JSONB, por qué el usuario de solo lectura.
3. **Valor de los datos** (1.5 min). Las cinco decisiones de negocio que ya están en el informe de la Actividad 5: dónde abrir, dónde no competir de frente, con qué formato diferenciarse, cómo leer el poder de las cadenas, y por qué el seguimiento continuo vale más que una foto.
4. **Limitaciones y mejoras** (1.5 min). Single-AZ sin backups, credenciales en Secrets pero no en Secrets Manager, 46 registros de una sola extracción sin histórico. Y la ruta: apagado programado, Multi-AZ, PostGIS si crece el volumen.

Repártanse los bloques entre los tres: se nota y suele valorarse.

---

## Fase 7 — Apagado (10 min, obligatorio)

```bash
sudo microk8s helm3 -n observabilidad uninstall grafana
```

Y en la consola:

1. **EC2** → seleccionar `microk8s-grafana` → Instance state → **Terminate**
2. **RDS** → `cafeterias-db` → Acciones → **Eliminar** (sin instantánea final)
3. Captura de ambas pantallas: la instancia en `Terminated` y RDS en 0 bases de datos
4. **End Lab**

Esas dos capturas son entregable obligatorio del FinOps.

---

## Resumen de lo que deben capturar

| # | Evidencia | Dónde |
|---|---|---|
| 1 | Conteo 46 registros / 46 ids únicos | Salida de `preparar-rds.sh` |
| 2 | Nodo del clúster | `kubectl get nodes` |
| 3 | Pods y servicio | `kubectl -n observabilidad get pods,svc` |
| 4 | Release de Helm | `helm3 -n observabilidad list` |
| 5 | Secrets y ConfigMap | `kubectl -n observabilidad get secrets,configmaps` |
| 6 | Dashboard en vivo con la URL visible | Navegador |
| 7 | EC2 en estado Terminated | Consola EC2 |
| 8 | RDS en 0 bases de datos | Consola RDS |

Mándenme las de la 2 a la 5 y actualizo el informe: hay que reescribir la subsección sobre orquestación y recalcular la tabla de costos, porque la t3.medium cuesta el doble que la t3.small.
