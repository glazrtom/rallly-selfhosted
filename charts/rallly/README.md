# rallly

A Helm chart for [Rallly](https://rallly.co), the open-source scheduling tool. Feature-equivalent with the project's `docker-compose.yml` self-hosting stack: bundled PostgreSQL, bundled [Garage](https://garagehq.deuxfleurs.fr/) S3-compatible object storage, SMTP, OIDC single sign-on, and the housekeeping tasks that run on cron for rallly.co but are otherwise absent from a self-hosted install.

## Prerequisites

- Kubernetes 1.23+
- Helm 3.8+
- A default StorageClass (or an explicit one via `global.storageClass`) if using the bundled Postgres/Garage
- An Ingress controller if `ingress.enabled=true`

## Installing

```console
helm install rallly charts/rallly \
  --set baseUrl=https://rallly.example.com \
  --set supportEmail=admin@example.com
```

`baseUrl` and `supportEmail` are required — the chart fails fast via `values.schema.json` if either is missing.

This installs a bundled single-instance PostgreSQL and a bundled single-node Garage instance alongside the app. Generated credentials (`SECRET_PASSWORD`, database and object-storage passwords, `CRON_SECRET`) are created automatically on first install and preserved across `helm upgrade` — see [Generated secrets](#generated-secrets).

## Storage classes and persistence

Every bundled volume (Postgres data, Garage metadata, Garage data) resolves its StorageClass in this order: a per-volume override, then `global.storageClass`, then the cluster default.

```console
# Use the cluster default everywhere
helm install rallly charts/rallly -f my-values.yaml

# Point everything at Longhorn
helm install rallly charts/rallly -f my-values.yaml --set global.storageClass=longhorn

# Longhorn for Postgres, a faster class just for Garage's data volume
helm install rallly charts/rallly -f my-values.yaml \
  --set global.storageClass=longhorn \
  --set garage.persistence.data.storageClass=fast-nvme
```

A StorageClass value of `"-"` disables dynamic provisioning (`storageClassName: ""`) for that volume. Set `postgresql.persistence.existingClaim` to bring your own PVC instead of a generated `volumeClaimTemplate`.

**`volumeClaimTemplates` are immutable.** Changing a StorageClass on an existing release requires recreating the StatefulSet (and its data) — `helm upgrade` cannot move an existing volume to a different class.

## External database / object storage

Disable the bundled dependencies and point at your own:

```yaml
postgresql:
  enabled: false
externalDatabase:
  url: "postgresql://user:pass@my-postgres:5432/rallly"
  # or: existingSecret: my-db-secret / existingSecretKey: DATABASE_URL

garage:
  enabled: false
externalS3:
  endpoint: "https://s3.amazonaws.com"
  bucketName: "rallly-uploads"
  region: "us-east-1"
  accessKeyId: "..."
  secretAccessKey: "..."
  # or: existingSecret: my-s3-secret (keys S3_ACCESS_KEY_ID / S3_SECRET_ACCESS_KEY)
```

## Generated secrets

`SECRET_PASSWORD`, the bundled Postgres password, the bundled Garage RPC secret and access keys, and `CRON_SECRET` are generated on first install if left blank, and **read back from the existing Secret on every subsequent `helm upgrade`** so they never change underneath a running deployment. Regenerating `SECRET_PASSWORD` invalidates all sessions; regenerating the Postgres/Garage credentials orphans existing data — set them explicitly in values (or via `existingSecret`) if you need to control them directly, e.g. for GitOps/ExternalSecrets workflows.

Every secret the chart manages can instead be supplied from a pre-existing Secret, so the chart generates nothing:

```yaml
# App secret: SECRET_PASSWORD, CRON_SECRET (if housekeeping enabled),
# and optionally SMTP_PWD / OIDC_CLIENT_SECRET.
existingSecret: rallly-app

postgresql:
  # keys: POSTGRES_USER / POSTGRES_PASSWORD / POSTGRES_DB
  existingSecret: rallly-postgresql

garage:
  # keys: GARAGE_RPC_SECRET / GARAGE_DEFAULT_ACCESS_KEY / GARAGE_DEFAULT_SECRET_KEY
  existingSecret: rallly-garage
```

> **⚠️ ArgoCD / GitOps users must set every secret explicitly via `existingSecret`.**
> The self-generation behaviour relies on Helm's `lookup` function to read back the
> previously generated values. ArgoCD (and any tool that renders with `helm template`)
> has no live cluster access during rendering, so `lookup` returns empty on **every**
> render and the chart mints **new random credentials each time**. That rotates the
> Postgres/Garage passwords out from under the already-initialised data directories,
> breaking authentication (`P1000` from Postgres), and churns the app `SECRET_PASSWORD`.
> Supply externally-managed Secrets (e.g. Sealed Secrets / External Secrets) via the
> `existingSecret` keys above so the values stay stable across renders.

## Single sign-on (OIDC)

```yaml
oidc:
  enabled: true
  name: "Corporate SSO"
  discoveryUrl: "https://idp.example.com/.well-known/openid-configuration"
  clientId: "rallly"
  clientSecret: "..."
```

## Housekeeping

Rallly's hosted service runs four maintenance tasks on a schedule (auto-close polls, delete inactive polls, remove soft-deleted polls and users); a self-hosted install runs none of these unless something calls them. This chart ships them as CronJobs, **enabled by default**, matching rallly.co's own schedule (`housekeeping.tasks`). These tasks delete data — review the schedule and disable (`housekeeping.enabled: false`) if you'd rather run it manually or not at all.

## Migrating from `kubernetes/`

If you're moving from this repository's plain `kubernetes/` manifests: they lack object storage, SMTP authentication, and OIDC entirely, and pin a stale image/Postgres version. There is no automated migration path for existing data — back up your database (`pg_dump`) before switching, point `externalDatabase.url` at your existing Postgres instance (or dump/restore into the chart's bundled one), and set `garage.enabled=false` with `externalS3.*` if you already have working object storage, or accept that uploads made before this chart was introduced will need to be migrated into Garage separately.

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity rules for the app pods. |
| allowedEmails | string | `""` | Comma-separated list of allowed email addresses/wildcards, e.g. "*@example.com". Empty allows all. |
| autoscaling.enabled | bool | `false` | Enable a HorizontalPodAutoscaler for the app. Note: rate limiting is in-memory per pod — set extraEnv KV_REST_API_URL/KV_REST_API_TOKEN (Upstash Redis) before scaling beyond 1 replica in production. |
| autoscaling.maxReplicas | int | `5` | Maximum replica count. |
| autoscaling.minReplicas | int | `1` | Minimum replica count. |
| autoscaling.targetCPUUtilizationPercentage | int | `80` | Target average CPU utilization. |
| autoscaling.targetMemoryUtilizationPercentage | string | `""` | Target average memory utilization. |
| baseUrl | required | `""` | Full public URL Rallly builds links against, e.g. https://rallly.example.com. Must include scheme and match the Ingress host. |
| caCert.enabled | bool | `false` | Mount a custom root CA certificate and set NODE_EXTRA_CA_CERTS, for networks that intercept TLS with a corporate root CA. |
| caCert.secretKey | string | `"ca.crt"` | Key within the Secret holding the PEM-encoded certificate. |
| caCert.secretName | string | `""` | Name of an existing Secret containing the CA certificate. |
| containerSecurityContext.allowPrivilegeEscalation | bool | `false` | Disallow privilege escalation. |
| containerSecurityContext.capabilities.drop | list | `["ALL"]` | Linux capabilities to drop. |
| containerSecurityContext.readOnlyRootFilesystem | bool | `false` | Mount the root filesystem read-only. Left false: the Next.js standalone server writes to .next/cache at runtime. |
| emailLogin.enabled | bool | `true` | Enable magic-link email login. Set to false to enforce SSO-only login. |
| existingSecret | string | `""` | Name of an existing Secret supplying the app credentials, instead of the chart-managed one. When set, the chart renders no app Secret and reads all app-level keys from it: SECRET_PASSWORD, CRON_SECRET (if housekeeping enabled), and optionally SMTP_PWD / OIDC_CLIENT_SECRET. Required for ArgoCD/GitOps — see README. |
| externalDatabase | object | `{"existingSecret":"","existingSecretKey":"DATABASE_URL","url":""}` | Full postgres:// connection URL. Used only when postgresql.enabled is false. |
| externalDatabase.existingSecret | string | `""` | Name of an existing Secret containing the DATABASE_URL key, instead of a plain-text url. |
| externalDatabase.existingSecretKey | string | `"DATABASE_URL"` | Key within existingSecret holding the connection URL. |
| externalS3 | object | `{"accessKeyId":"","bucketName":"","endpoint":"","existingSecret":"","region":"","secretAccessKey":""}` | S3 endpoint URL, e.g. https://s3.amazonaws.com or https://<account>.r2.cloudflarestorage.com. Used only when garage.enabled is false. |
| externalS3.accessKeyId | string | `""` | S3 access key ID. |
| externalS3.bucketName | string | `""` | S3 bucket name. |
| externalS3.existingSecret | string | `""` | Name of an existing Secret containing S3 credentials, instead of plain-text keys. |
| externalS3.region | string | `""` | S3 region. |
| externalS3.secretAccessKey | string | `""` | S3 secret access key. Stored in the app Secret. |
| extraEnv | list | `[]` | Extra environment variables for the app container, e.g. KV_REST_API_URL/KV_REST_API_TOKEN, branding vars, MODERATION_*, NEXT_PUBLIC_CDN_BASE_URL. Accepts the full corev1 EnvVar schema. |
| extraManifests | list | `[]` | Extra raw Kubernetes manifests to install alongside the chart. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the app container. |
| extraVolumes | list | `[]` | Extra volumes for the app pod. |
| garage.accessKeyId | string | `""` | Garage/S3 access key. Auto-generated and persisted across upgrades if left empty. |
| garage.bucketName | string | `"rallly"` | Default bucket created and used for uploads. |
| garage.enabled | bool | `true` | Deploy a bundled single-node Garage StatefulSet for S3-compatible object storage. Set to false to use `externalS3`. |
| garage.existingSecret | string | `""` | Name of an existing Secret supplying the bundled Garage credentials, instead of the chart-managed one. When set, the chart renders no Garage Secret and reads keys GARAGE_RPC_SECRET / GARAGE_DEFAULT_ACCESS_KEY / GARAGE_DEFAULT_SECRET_KEY from it. Required for ArgoCD/GitOps — see README. |
| garage.image.registry | string | `"docker.io"` | Garage image registry |
| garage.image.repository | string | `"dxflrs/garage"` | Garage image repository |
| garage.image.tag | string | `"v2.3.0"` | Garage image tag |
| garage.persistence.data.accessModes | list | `["ReadWriteOnce"]` | Access modes for the Garage data volume. |
| garage.persistence.data.size | string | `"10Gi"` | Size of the Garage data volume. |
| garage.persistence.data.storageClass | string | `""` | StorageClass for the Garage data volume. |
| garage.persistence.meta.accessModes | list | `["ReadWriteOnce"]` | Access modes for the Garage metadata volume. |
| garage.persistence.meta.size | string | `"1Gi"` | Size of the Garage metadata volume. |
| garage.persistence.meta.storageClass | string | `""` | StorageClass for the Garage metadata volume. |
| garage.resources.limits | object | `{"cpu":"1","memory":"512Mi"}` | Resource limits for the Garage container. |
| garage.resources.requests | object | `{"cpu":"100m","memory":"128Mi"}` | Resource requests for the Garage container. |
| garage.rpcSecret | string | `""` | Garage inter-node RPC secret: 64 lowercase hex characters (32 bytes). Auto-generated and persisted across upgrades if left empty. |
| garage.secretAccessKey | string | `""` | Garage/S3 secret key. Auto-generated and persisted across upgrades if left empty. |
| global.imagePullSecrets | list | `[]` | Global list of imagePullSecrets, merged with image-specific ones. |
| global.imageRegistry | string | `""` | Global override for all image registries below. |
| global.storageClass | string | `""` | Default StorageClass for all bundled volumes (Postgres data, Garage meta/data). "" uses the cluster default. "-" disables dynamic provisioning (storageClassName: ""). Overridable per-volume below. |
| housekeeping.cronSecret | string | `""` | Bearer token required by /api/house-keeping/* endpoints. Auto-generated and persisted across upgrades if left empty. |
| housekeeping.enabled | bool | `true` | Run scheduled housekeeping CronJobs (auto-close polls, delete inactive/soft-deleted polls and users). These tasks DELETE data on a retention schedule — review `housekeeping.tasks` before enabling on data you want to keep indefinitely. |
| housekeeping.image.registry | string | `"docker.io"` | curl image registry used to call the housekeeping endpoints. |
| housekeeping.image.repository | string | `"curlimages/curl"` | curl image repository. |
| housekeeping.image.tag | string | `"8.11.1"` | curl image tag. |
| housekeeping.tasks | list | `[{"name":"auto-close-polls","schedule":"30 5 * * *"},{"name":"delete-inactive-polls","schedule":"0 6 * * *"},{"name":"remove-deleted-polls","schedule":"30 6 * * *"},{"name":"remove-deleted-users","schedule":"0 7 * * *"}]` | List of {name, schedule} housekeeping tasks. Schedules are UTC cron expressions, matching rallly.co's own schedule. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy |
| image.pullSecrets | list | `[]` | Image pull secrets |
| image.registry | string | `"docker.io"` | Image registry |
| image.repository | string | `"lukevella/rallly"` | Image repository |
| image.tag | string | `""` | Image tag. Defaults to the chart's appVersion. |
| ingress.annotations | object | `{}` | Extra annotations for the Ingress, e.g. cert-manager.io/cluster-issuer. |
| ingress.className | string | `""` | IngressClass to use. |
| ingress.enabled | bool | `false` | Create an Ingress for the app. |
| ingress.host | string | `""` | Hostname to route to the app. Should match the host portion of `baseUrl`. |
| ingress.tls | object | `{"enabled":false,"secretName":""}` | Enable TLS on the Ingress. |
| ingress.tls.secretName | string | `""` | Name of the TLS Secret. Leave empty if using cert-manager to provision it. |
| initialAdminEmail | string | `""` | Email of the first user allowed to claim admin at /control-panel. |
| migrationJob.backoffLimit | int | `2` | Number of retries for the migration Job before it is considered failed. |
| migrationJob.enabled | bool | `false` | Run `prisma migrate deploy` as a pre-upgrade Helm hook. The app image always migrates on its own at startup under an advisory lock; this only makes a broken migration fail the upgrade before pods roll, instead of crashlooping app pods. |
| networkPolicy.allowExternalEgress | bool | `true` | Allow all egress from app pods (needed for SMTP/external S3/OIDC to arbitrary hosts). Disable and use extraEgressRules to lock this down further. |
| networkPolicy.enabled | bool | `false` | Create NetworkPolicies restricting traffic to the app, Postgres and Garage. |
| networkPolicy.ingressNamespaceSelector | object | `{}` | Namespace selector allowed to reach the app on its Service port, e.g. an ingress-controller namespace. Empty allows from anywhere in the cluster. |
| nodeSelector | object | `{}` | Node selector for the app pods. |
| noreplyEmail | string | `""` | Sender address for system emails. Falls back to supportEmail if unset. |
| oidc.clientId | string | `""` | OIDC client ID. |
| oidc.clientSecret | string | `""` | OIDC client secret. Stored in the app Secret. |
| oidc.discoveryUrl | string | `""` | OIDC discovery URL (.well-known/openid-configuration). |
| oidc.enabled | bool | `false` | Enable OIDC single sign-on. |
| oidc.name | string | `"OpenID Connect"` | Display name for the OIDC login button. |
| podAnnotations | object | `{}` | Extra annotations for the app pods. |
| podDisruptionBudget.enabled | bool | `false` | Create a PodDisruptionBudget for the app. Only useful with replicaCount/autoscaling.minReplicas >= 2. |
| podDisruptionBudget.minAvailable | int | `1` | Minimum available pods during a voluntary disruption. |
| podLabels | object | `{}` | Extra labels for the app pods. |
| podSecurityContext.fsGroup | int | `101` |  |
| podSecurityContext.runAsNonRoot | bool | `true` | Require the pod to run as non-root. |
| podSecurityContext.runAsUser | int | `100` | UID to run as. Matches the image's built-in `nextjs` user. |
| postgresql.dataMountPath | string | `"/var/lib/postgresql"` | Path the data volume is mounted at. postgres:18+ requires /var/lib/postgresql; older majors need /var/lib/postgresql/data. |
| postgresql.database | string | `"rallly"` | Database name. |
| postgresql.enabled | bool | `true` | Deploy a bundled PostgreSQL StatefulSet. Set to false to use an external database via `externalDatabase`. |
| postgresql.existingSecret | string | `""` | Name of an existing Secret supplying the bundled Postgres credentials, instead of the chart-managed one. When set, the chart renders no Postgres Secret and reads keys POSTGRES_USER / POSTGRES_PASSWORD / POSTGRES_DB from it. Required for ArgoCD/GitOps — see README. |
| postgresql.image.registry | string | `"docker.io"` | PostgreSQL image registry |
| postgresql.image.repository | string | `"library/postgres"` | PostgreSQL image repository |
| postgresql.image.tag | string | `"18-alpine"` | PostgreSQL image tag. 18 moved PGDATA to /var/lib/postgresql — see dataMountPath. |
| postgresql.password | string | `""` | Database password. Auto-generated and persisted across upgrades if left empty. |
| postgresql.persistence.accessModes | list | `["ReadWriteOnce"]` | Access modes for the Postgres data volume. |
| postgresql.persistence.annotations | object | `{}` | Extra annotations for the PVC. |
| postgresql.persistence.enabled | bool | `true` | Use a PersistentVolumeClaim for Postgres data. Disabling loses all data on pod restart. |
| postgresql.persistence.existingClaim | string | `""` | Use an existing PVC instead of a volumeClaimTemplate. Skips provisioning. |
| postgresql.persistence.size | string | `"8Gi"` | Size of the Postgres data volume. |
| postgresql.persistence.storageClass | string | `""` | StorageClass override for this volume. Falls back to global.storageClass, then the cluster default. |
| postgresql.resources.limits | object | `{"cpu":"2","memory":"2Gi"}` | Resource limits for the Postgres container. |
| postgresql.resources.requests | object | `{"cpu":"250m","memory":"512Mi"}` | Resource requests for the Postgres container. |
| postgresql.username | string | `"rallly"` | Database username. |
| priorityClassName | string | `""` | Priority class for the app pods. |
| probes.liveness.initialDelaySeconds | int | `0` | Liveness probe initial delay. |
| probes.liveness.periodSeconds | int | `10` | Liveness probe period. |
| probes.readiness.initialDelaySeconds | int | `0` | Readiness probe initial delay. |
| probes.readiness.periodSeconds | int | `5` | Readiness probe period. |
| probes.startup.failureThreshold | int | `30` | Startup probe failure threshold. Combined with periodSeconds, this must budget enough time for `prisma migrate deploy` to complete on first boot. |
| probes.startup.periodSeconds | int | `10` | Startup probe period. |
| registration.enabled | bool | `true` | Allow new user registration. |
| replicaCount | int | `1` | Number of Rallly pods. Rate limiting is in-memory per pod unless `extraEnv` sets KV_REST_API_URL/KV_REST_API_TOKEN (Upstash Redis) — see kv.md in README. |
| resources | object | `{"limits":{"cpu":"1","memory":"1Gi"},"requests":{"cpu":"200m","memory":"512Mi"}}` | Resource requests/limits for the app container. |
| secretPassword | string | `""` | Session encryption key, min 32 chars. Auto-generated and persisted across upgrades if left empty. Changing it invalidates all sessions. |
| service.port | int | `80` | Service port. |
| service.type | string | `"ClusterIP"` | Kubernetes Service type for the app. |
| serviceAccount.annotations | object | `{}` | Extra annotations for the ServiceAccount. |
| serviceAccount.create | bool | `true` | Create a ServiceAccount for the app. |
| serviceAccount.name | string | `""` | Name of the ServiceAccount to use. Generated from the release name if not set. |
| smtp.host | string | `""` | SMTP server host. |
| smtp.password | string | `""` | SMTP password. Stored in the app Secret. |
| smtp.port | int | `587` | SMTP server port. |
| smtp.rejectUnauthorized | bool | `true` | Reject self-signed/invalid SMTP TLS certificates. |
| smtp.secure | bool | `false` | Use implicit TLS. true only for port 465; leave false for STARTTLS (587) or plain (25). |
| smtp.user | string | `""` | SMTP username. |
| supportEmail | required | `""` | Email address shown to users for support inquiries. Also the fallback sender address. |
| tolerations | list | `[]` | Tolerations for the app pods. |
| topologySpreadConstraints | list | `[]` | Topology spread constraints for the app pods. |
