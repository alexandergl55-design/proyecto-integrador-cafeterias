# Pipeline de datos en la nube para análisis de localización comercial

**Proyecto Integrador · Herramientas de Computación en la Nube**
Maestría en Analítica Aplicada · Universidad de La Sabana · Octubre de 2026

Antonia Gacharná Echeverri · Christian Fabián Jaimes Toscano · Efren Alexander Granados Latorre

---

## Qué hace este proyecto

Convierte una consulta a una API pública en un tablero de decisión comercial. El caso de estudio son las 46 cafeterías de la localidad de Teusaquillo, en Bogotá, extraídas de Foursquare Places API y validadas geográficamente contra el polígono oficial de la localidad.

La pregunta que articula el proyecto es de localización comercial: **dónde está saturada la oferta de cafeterías, dónde quedan vacíos de mercado y con qué formato puede diferenciarse un nuevo entrante.**

El pipeline no responde esa pregunta una sola vez. La capa de ingesta es idempotente y la de visualización consulta la base en vivo, de modo que una nueva extracción se refleja en el tablero sin trabajo manual. Eso convierte una fotografía en seguimiento continuo de aperturas y cierres.

---

## Arquitectura

![Arquitectura del pipeline](img/arquitectura.png)

| Etapa | Servicio y configuración | Modelo | Función |
|---|---|---|---|
| Extracción | Foursquare Places API | SaaS externo | 46 POI, categorías Coffee Shop y Café |
| Zona cruda | Amazon S3 — `raw_zone/cafeterias/` | Almacenamiento | Dato original inmutable, CSV de 9,2 KB |
| Transformación | AWS Lambda, Python 3.10, 256 MB | FaaS | Tipificación, serialización JSONB, UPSERT |
| Persistencia | Amazon RDS PostgreSQL db.t3.micro | PaaS | Tabla `cafeterias_teusaquillo`, 20 GB, Single-AZ |
| Visualización | Amazon EC2 t3.medium + MicroK8s 1.31 + Helm + Grafana OSS 12.3 | IaaS + orquestación | Release de Helm, 9 paneles, NodePort 30000 |
| Observabilidad | Amazon CloudWatch Logs | Gestionado | Duración, memoria y estado por invocación |

En cada etapa se eligió deliberadamente un modelo de servicio distinto según la naturaleza del trabajo: almacenamiento gestionado para el dato crudo, cómputo sin servidor para una transformación que dura milisegundos, base administrada para el dato estructurado, e infraestructura como servicio con orquestación de contenedores para la capa que el equipo opera directamente.

### Qué se orquesta en Kubernetes y qué no

Lambda y RDS son servicios administrados de AWS: no se integran dentro de un clúster ni tendría sentido intentarlo. Lo que se orquesta en MicroK8s es la **capa de visualización**. Grafana dejó de ser un contenedor lanzado a mano con `docker run` para convertirse en un *release* de Helm con su Deployment, su Service de tipo NodePort, dos Secrets y un ConfigMap.

Se eligió MicroK8s sobre Amazon EKS por una razón económica: un plano de control gestionado cuesta 0,10 USD por hora —unos 73 USD mensuales, más que el pipeline completo—, mientras que MicroK8s corre dentro de la misma instancia. Su costo marginal es el salto de `t3.small` a `t3.medium` que exigen sus 2 vCPU y 4 GB.

Con un solo nodo, Kubernetes reinicia el pod si el proceso falla, pero no protege frente a la caída de la instancia. Lo que se gana aquí es reproducibilidad y gestión declarativa, no disponibilidad.

---

## Modelo de datos

El modelo se resuelve en una sola entidad. Con 46 registros y un dominio sin relaciones externas, normalizar habría añadido complejidad sin beneficio; la decisión relevante no fue cuántas tablas crear sino cómo tipificar cada atributo.

La más significativa es el uso de **JSONB** para las categorías. Un establecimiento puede pertenecer a varias a la vez: nueve de los 46 combinan cafetería con panadería, coworking o incluso venta de bicicletas. La alternativa normalizada exigía dos tablas y un JOIN para un atributo que proviene de una taxonomía externa, sobre la que el proyecto no tiene control ni necesidad de integridad referencial.

```sql
-- establecimientos que además operan como panadería
SELECT name FROM cafeterias_teusaquillo
WHERE categories @> '["Bakery"]';

-- frecuencia de todas las categorías declaradas
SELECT cat.value AS categoria, COUNT(*) AS establecimientos
FROM cafeterias_teusaquillo c,
     LATERAL jsonb_array_elements_text(c.categories) AS cat(value)
GROUP BY cat.value ORDER BY establecimientos DESC;
```

El índice GIN sobre `categories` permite resolver la contención (`@>`) con eficiencia. Esta elección se revisaría si las categorías requirieran atributos propios o si el volumen creciera en un orden de magnitud.

---

## Estructura del repositorio

```
.
├── README.md
├── Reporte_Proyecto_Integrador.pdf      Informe general (6 secciones, FinOps, evidencias)
├── Presentacion_Proyecto_Integrador.pptx Soporte de la sustentación en video
├── img/
│   └── arquitectura.png                 Diagrama completo del pipeline
└── microk8s/
    ├── preparar-rds.sh                  Crea base, tabla, carga las 46 filas y el usuario de lectura
    ├── desplegar-microk8s.sh            Instala MicroK8s y despliega Grafana con Helm
    ├── values.yaml                      Valores del chart: NodePort, Secrets, datasource, dashboard
    ├── cafeterias.json                  Dashboard de 9 paneles como ConfigMap
    ├── RUNBOOK.md                       Guion de la sesión completa, por fases
    └── PASOS.md                         Despliegue paso a paso y diagnóstico de fallos
```

---

## Cómo reproducir el despliegue

### Requisitos

- Una cuenta de AWS con permisos sobre EC2 y RDS (el proyecto se desarrolló en AWS Academy Learner Lab).
- Una instancia RDS PostgreSQL disponible.
- Una instancia EC2 **t3.medium** con Ubuntu Server 24.04 y 20 GB de disco, en el mismo grupo de seguridad que RDS.
- Reglas de entrada en ese grupo: SSH (22) desde su IP y TCP personalizado (30000) para el tablero.

### Pasos

```bash
# 1. Copiar los archivos a la instancia
scp -i llave.pem microk8s/* ubuntu@IP_PUBLICA:~/

# 2. Conectarse
ssh -o ServerAliveInterval=60 -i llave.pem ubuntu@IP_PUBLICA

# 3. Preparar la base de datos
sudo bash preparar-rds.sh      # debe imprimir 46 registros y 46 ids únicos

# 4. Desplegar el clúster y Grafana
sudo bash desplegar-microk8s.sh
```

El segundo script instala MicroK8s, habilita `dns`, `hostpath-storage` y `helm3`, crea el namespace `observabilidad`, guarda las credenciales como Secrets, monta el dashboard como ConfigMap y despliega Grafana con Helm. Tarda entre 10 y 15 minutos y es idempotente: si la conexión se corta, basta volver a ejecutarlo.

Al terminar, el tablero queda en `http://IP_PUBLICA:30000` con acceso anónimo de solo lectura.

### Verificación

```bash
sudo microk8s kubectl get nodes
sudo microk8s kubectl -n observabilidad get pods,svc
sudo microk8s helm3 -n observabilidad list
sudo microk8s kubectl -n observabilidad get secrets,configmaps
```

### Apagado

```bash
sudo microk8s helm3 -n observabilidad uninstall grafana
```

Y desde la consola: terminar la instancia EC2 y eliminar la base RDS sin instantánea final.

---

## Manejo de credenciales

El proyecto sigue el principio de confianza cero que exige el curso: **ninguna credencial está escrita en el código ni versionada en este repositorio.**

- Las claves de API se leen de un archivo `.env` con permisos `600`, excluido mediante `.gitignore`.
- Los scripts de despliegue piden las contraseñas por teclado y las guardan como **Secrets de Kubernetes**; `values.yaml` solo las referencia por nombre de clave, nunca por valor.
- El acceso de la EC2 a S3 se resuelve con el rol de IAM `LabInstanceProfile`, sin llaves estáticas.
- Grafana se conecta a la base con el usuario `grafana_reader`, que solo tiene permiso `SELECT`. Nunca con el usuario administrador.

Los Secrets de Kubernetes codifican en base64 pero no cifran en reposo mientras no se habilite el cifrado del almacén de etcd. Migrarlos a AWS Secrets Manager es la medida de seguridad propuesta en la sección 7 del informe.

---

## Costos (FinOps)

Precios de lista de `us-east-1`, bajo el supuesto de operación continua (730 horas al mes).

| Componente | Precio unitario | Consumo | USD / mes |
|---|---|---|---|
| EC2 t3.medium (MicroK8s + Grafana) | 0,0416 USD/hora | 730 horas | 30,37 |
| Volumen EBS gp3 de la EC2 | 0,080 USD/GB-mes | 20 GB | 1,60 |
| RDS db.t3.micro PostgreSQL | 0,018 USD/hora | 730 horas | 13,14 |
| Almacenamiento RDS gp2 | 0,115 USD/GB-mes | 20 GB | 2,30 |
| AWS Lambda | 0,20 USD/millón + GB-s | 30 inv. × 272 ms | 0,00 |
| Amazon S3 Standard | 0,023 USD/GB-mes | 9,2 KB | 0,00 |
| **Total** | | | **47,41** |

El cómputo concentra el 91,8 % del gasto. La capa serverless es efectivamente gratuita: treinta invocaciones mensuales consumen 2,04 GB-segundo frente a los 400.000 de la capa gratuita permanente de Lambda, mientras que el mismo trabajo sobre una instancia encendida habría costado alrededor de 15 USD al mes.

Como el costo del cómputo se devenga por hora encendida, **apagar los recursos fuera de uso es la palanca de ahorro más eficaz** y no requiere rediseñar nada: un apagado programado en horario laboral baja el costo de la instancia de 31,97 a 12,58 USD.

Durante el desarrollo el consumo real fue una fracción de la cifra anterior, porque las instancias solo estuvieron encendidas durante las sesiones de laboratorio y se terminaron al cerrar cada una.

---

## Artefactos de las actividades anteriores

| Actividad | Artefactos | Repositorio |
|---|---|---|
| 2 · Ingesta | Script de extracción de Foursquare, CSV validado, análisis exploratorio | [Antoniaga/actividad-cafeterias-teusaquillo](https://github.com/Antoniaga/actividad-cafeterias-teusaquillo) |
| 3 · Modelo y carga | Script DDL, notebook de JupyterHub, modelo entidad-relación | [alexandergl55-design/actividad3-cafeterias-rds](https://github.com/alexandergl55-design/actividad3-cafeterias-rds) |
| 4 · Serverless | Función Lambda, paquete `.zip`, SQL de validación de idempotencia | [Antoniaga/actividad4-lambda-cafeterias-rds](https://github.com/Antoniaga/actividad4-lambda-cafeterias-rds) |
| 5 · Visualización | Dashboard JSON, provisioning, `instalar.sh`, consultas SQL | [christian130994-coder/grafana-cafeterias-teusaquillo_](https://github.com/christian130994-coder/grafana-cafeterias-teusaquillo_) |

---

## Limitaciones conocidas

- La base opera en Single-AZ y sin copias de seguridad automáticas: no hay objetivos de recuperación definidos.
- El clúster tiene un solo nodo, de modo que la caída de la instancia deja el tablero inaccesible pese a la orquestación.
- La función Lambda captura sus excepciones pero no las relanza, lo que impide que los reintentos automáticos se activen ante un fallo.
- Son 46 registros de una sola extracción: no hay histórico temporal que permita medir variación.
- Las distancias se miden desde el punto central de la consulta a la API, y la cuadrícula cubre el rectángulo que envuelve los puntos, no el polígono real de la localidad. Por eso algunas celdas vacías corresponden a parques o campus universitarios.

La ruta de evolución propuesta, ordenada por retorno, está en la sección 7 del informe.
