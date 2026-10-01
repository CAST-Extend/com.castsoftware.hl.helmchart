# Highlight 6 - Helm chart (Kubernetes / OpenShift)

Deploys the full CAST Highlight 6 stack (postgres, keycloak, cvedb, highlightportal) on Kubernetes
(AKS, EKS, GKE, on-prem/bare-metal) or OpenShift, with a single external entry point.

This is the Kubernetes counterpart of `hl-docker/docker-compose` - same images, same components,
same `/` -> portal and `/auth` -> Keycloak routing. The Ingress / OpenShift Routes take the place of
the compose stack's nginx gateway.

- Chart name: `k8s-cloud`, chart version / app version `6.0.1`
- Images: `jartero/highlightportal:6.0.1`, `jartero/cvedb:6.0.1`, `jartero/hlkeycloak:1.0.6`,
  `postgres:17`, `castimaging/init-util:1.2.11`

## Contents

1. [Architecture](#architecture)
2. [Layout](#layout)
3. [Prerequisites](#prerequisites)
4. [Configuration](#configuration)
5. [Deploy on Kubernetes - Ingress (HTTPS, recommended)](#deploy-on-kubernetes---ingress-https-recommended)
6. [Deploy on Kubernetes - NodePort (HTTP, no ingress controller)](#deploy-on-kubernetes---nodeport-http-no-ingress-controller)
7. [Restricted security mode](#restricted-security-mode)
8. [Deploy on OpenShift](#deploy-on-openshift)
9. [Verify the deployment and first login](#verify-the-deployment-and-first-login)
10. [Day-2 operations](#day-2-operations)
11. [Uninstall and data cleanup](#uninstall-and-data-cleanup)
12. [Troubleshooting](#troubleshooting)
13. [Values reference](#values-reference)

## Architecture

```
                         Browser
                            |
            https://<gateway.host>/          https://<gateway.host>/auth
                            |                          |
               +------------v--------------------------v-----------+
               |  Ingress (NGINX)  /  OpenShift Routes  /  NodePort |   <- only thing exposed
               +------------+--------------------------+-----------+
                            |                          |
                  highlightportal:8080          keycloak:8080 (/auth)
                   |        |     ^                    |
                   |        |     +---- webhook -------+
                   |        v                          |
                   |    cvedb:8082                     |
                   |        |                          |
                   v        v                          v
               +---------------------------------------------+
               | postgres:5432 (StatefulSet)                 |
               |  db "highlight"  (schemas highlight, cvedb) |
               |  db "keycloak"   (schema keycloak)          |
               +---------------------------------------------+
```

| Component | Kind | Service | Exposed outside the cluster |
|---|---|---|---|
| `postgres` | StatefulSet | `postgres` (ClusterIP) + `postgres-headless` | Never |
| `cvedb` | Deployment | `cvedb:8082` (ClusterIP) | Never |
| `keycloak` | Deployment | `keycloak:8080` | Through the gateway, under `/auth` |
| `highlightportal` | Deployment | `highlightportal:8080` | Through the gateway, under `/` |

Start-up order is enforced with init containers (the `castimaging/init-util` image):

- `cvedb` and `keycloak` wait for `postgres` (`pg_isready`).
- `highlightportal` waits for `postgres`, then for `cvedb` to answer HTTP 200, then for Keycloak's
  `/auth/realms/master` to answer HTTP 200. If the portal starts before Keycloak is ready, it gets
  stuck in `KEYCLOAK_CHECK_CONFIGURATION` and needs a restart. The init container prevents this.

Postgres databases, schemas and users are created on first start by the `init-db.sh` script in the
`init-db` ConfigMap ([templates/postgres-configmap.yaml](templates/postgres-configmap.yaml)).

### Exposure modes (`networking.type`)

| Mode | Use it for | What gets created | URL |
|---|---|---|---|
| `ingress` (default) | Managed Kubernetes (AKS/EKS/GKE) or on-prem clusters with an NGINX ingress controller | One `Ingress` named `highlight-gateway`: `/auth` -> keycloak, `/` -> portal | `https://<gateway.host>` |
| `nodeport` | Bare-metal, lab and test clusters without an ingress controller or certificate | Portal and Keycloak Services become `NodePort` | `http://<node>:<portalPort>` (Keycloak on `http://<node>:<keycloakPort>/auth`) |
| `route` | OpenShift | Two `Route`s (`highlight-keycloak` on `/auth`, `highlight-portal` on `/`), edge TLS at the router | `https://<gateway.host>` |

Every browser-facing URL in the app config (`HL_ROOT_URL`, Keycloak's `KC_HOSTNAME` and
`APP_BASE_URL`, `HL_KEYCLOAK_ADMIN_URL`) is derived from `gateway.*` and `networking.*`. You set the
hostname **once**, in `gateway.host`. The compose stack needs it in several places; the chart does
not.

## Layout

```
hl-helmchart/
├── Chart.yaml
├── values.yaml                 # default, non-sensitive settings (hostname, networking, SMTP hosts, images, sizes)
├── values-secret.yaml          # CHANGEME template for every password, client secret, API key and license key
├── values-openshift.yaml       # overlay for OpenShift: openshift.enabled=true, networking.type=route
├── helm-install.bat            # Windows helper: helm upgrade --install with values.yaml + values-secret.yaml
├── helm-delete.bat             # Windows helper: helm delete (PVCs are kept, see "Uninstall")
├── Util-DeleteStorage.bat      # Windows helper: deletes the persistent volume claims (destroys all data)
├── Util-SyncDbPasswords.bat    # Windows helper: resyncs Postgres role passwords with the current values
└── templates/
    ├── _helpers.tpl                          # URL builders, securityContext helpers, networking.type guard
    ├── ingress.yaml                          # networking.type=ingress
    ├── routes.yaml                           # networking.type=route (OpenShift)
    ├── highlight-secret.yaml                 # "highlight-pwd-sec" Secret (skipped when existingSecret is set)
    ├── highlightportal-{deployment,service,configmap,pvc,config-pvc}.yaml
    ├── keycloak-{deployment,service,configmap,pvc}.yaml
    ├── cvedb-{deployment,service,configmap}.yaml
    └── postgres-{statefulset,service,headless-service,configmap,pvc}.yaml
```

> **Secrets and license notice:** `values-secret.yaml` holds every password, client secret, the NIST
> API key and the Highlight license keys. The chart renders them into the `highlight-pwd-sec`
> Secret in the release namespace (never into ConfigMaps), and the pods read them from it as env
> vars. Don't commit real values. Copy the template to a file that git ignores, or pass the values
> with `--set` or Sealed Secrets/SOPS. To keep them out of Helm entirely, point `existingSecret` at
> a Secret managed by an external secret store (see
> [Using an external Secret](#using-an-external-secret-existingsecret)). Fill in every
> `CHANGEME` value **before the first install**: Postgres and Keycloak read several of them only
> once, on first start (see [Day-2 operations](#day-2-operations)).

## Prerequisites

### Tools

- `kubectl` (or `oc` for OpenShift), configured for the target cluster
- Helm 3.8 or later
- Pull access to the images listed at the top of this page, from Docker Hub or a mirror. For an
  air-gapped cluster, mirror them and override the `*Image.name` values.

### Cluster capacity

The default resource settings, in [values.yaml](values.yaml):

| Component | CPU request | Memory request | Memory limit |
|---|---|---|---|
| postgres | 0.5 | 8G | 8G |
| highlightportal | 0.5 | 8G | 16G |
| cvedb | 0.5 | 4G | 6G |
| keycloak | 0.5 | 1G | 1G |
| **Total** | **2 vCPU** | **~21G** | **~31G** |

Postgres and the portal each need a node with at least 8G of allocatable memory. Smaller nodes
leave those pods `Pending`. On a small test cluster, lower `*Resources` in a values override.

### Storage

The chart needs a StorageClass that dynamically provisions `ReadWriteOnce` volumes. Leave
`storageClass.name` empty to use the cluster default. Examples: `managed-csi` (AKS), `gp2`/`gp3`
(EKS), `standard-rwo` (GKE), `local-path` (k3s/Rancher), `gp3-csi` (ROSA),
`crc-csi-hostpath-provisioner` (OpenShift Local).

| PVC | Used by | Default size |
|---|---|---|
| `db-data-highlight` | postgres data | 50Gi (`storageClass.postgresSize`) |
| `tmp-highlight` | portal `/tmp` (includes `.hl-envfile`) | 5Gi (`storageClass.portalTmpSize`) |
| `highlightportal-config` | portal `/config` (SAML SP config) | 100Mi (`storageClass.portalConfigSize`) |
| `keycloak-data` | Keycloak `/opt/keycloak/data` (includes the "already initialized" sentinel) | 1Gi (`storageClass.keycloakSize`) |

Every PVC has the annotation `helm.sh/resource-policy: keep`, so `helm uninstall` does **not** delete
it. See [Uninstall and data cleanup](#uninstall-and-data-cleanup).

### External services

- An **SMTP server** for Keycloak, the portal and cvedb (hosts and ports in `values.yaml`,
  passwords in `values-secret.yaml`).
- A **NIST NVD API key** (`Cvedb.nistApiKey`). cvedb uses it to download CVE data.
  Request one at <https://nvd.nist.gov/developers/request-an-api-key>.
- A **Highlight license** (`HighlightPortal.license.key*`).

### Networking and TLS (ingress and route modes)

- A DNS record for `gateway.host` that points at the ingress controller's external address (or the
  OpenShift router). It must resolve **from inside the cluster too**: the portal pod calls
  Keycloak's admin API through `https://<gateway.host>/auth`, not through the internal Service.
- A TLS certificate for `gateway.host` that the **portal's JVM trusts**, which in practice means one
  from a public CA (Let's Encrypt, DigiCert, and so on). The chart doesn't inject a custom trust
  store and keeps `HL_KEYCLOAK_DISABLE_SSL_VALIDATION=false`. With a self-signed or private-CA
  certificate, browser logins work (after the warning) but the portal's server-side calls to
  Keycloak fail. For those, use NodePort mode or a publicly trusted certificate.

## Configuration

The chart splits its configuration across two files that are always passed together:

| File | Content | Commit to git? |
|---|---|---|
| [values.yaml](values.yaml) | Hostname, networking mode, images, SMTP hosts and users, e-mail addresses, resources, storage | Yes |
| [values-secret.yaml](values-secret.yaml) | Every password, client secret, the NIST API key and license keys (`CHANGEME` placeholders) | **Template only**. Keep real values in an untracked copy. |

The recommended workflow keeps the tracked files untouched and puts site-specific values in local
override files, applied last:

```bash
cp values-secret.yaml values-secret.local.yaml   # fill in real secrets here - never commit it
cp values.yaml        values.local.yaml          # optional: site-specific non-secret overrides
```

### 1. Non-secret values (`values.yaml` or your override)

At minimum, review:

| Key | What to set |
|---|---|
| `gateway.host` | Public hostname of the deployment, e.g. `highlight.mycompany.com`. In NodePort mode, a node hostname or IP. |
| `gateway.protocol` / `gateway.port` | `https` and empty (port 443) for ingress and route. Ignored in NodePort mode. |
| `networking.type` | `ingress`, `nodeport` or `route` |
| `networking.ingress.className` | Your ingress class (`nginx`, or `webapprouting.kubernetes.azure.com` for the AKS app-routing add-on) |
| `networking.ingress.tls.secretName` | Name of the TLS secret you create in the namespace (default `tls-secret-cast`) |
| `storageClass.name` | Empty for the default StorageClass, or an explicit class name |
| `Keycloak.permanentAdmin.email`, `Cvedb.administratorMail`, `HighlightPortal.admin.mail` | Real admin e-mail addresses |
| `Keycloak.smtp.*`, `Cvedb.smtp.*`, `HighlightPortal.smtp.*` | SMTP host, port, user and sender address for each component |

Leave `Keycloak.realmName` as `hl-portal`. The `hlkeycloak` entrypoint hard-codes the realm import
file name as `hl-portal-realm.json`, so a different realm name breaks the import.

### 2. Secret values (`values-secret.local.yaml`)

Replace every `CHANGEME` value:

| Key | Purpose |
|---|---|
| `Postgres.superuser.password` | `postgres` superuser. cvedb also uses it as its datasource password. |
| `Postgres.highlightUser.password`, `Postgres.highlightRootUser.password` | Highlight database roles (the portal connects as `highlight_root`) |
| `Keycloak.database.password` | `keycloak` database role |
| `Keycloak.bootstrapAdmin.password` | Temporary admin, used during the first Keycloak init only and deleted afterwards |
| `Keycloak.permanentAdmin.password` | Keycloak admin console account (`admin` by default) |
| `Keycloak.portalClientSecret` | OIDC secret of the `highlight-portal` client |
| `Keycloak.adminClientSecret` | Secret of the `highlight-admin` client (admin API) |
| `Keycloak.webhookSecret` | Shared secret for the Keycloak -> portal event webhook |
| `Keycloak.smtp.password`, `Cvedb.smtp.password`, `HighlightPortal.smtp.password` | SMTP passwords |
| `Cvedb.nistApiKey` | NIST NVD API key |
| `HighlightPortal.admin.password` | Initial Highlight admin password. It must satisfy the realm policy: 14+ characters, with at least 1 digit, 1 uppercase letter, 1 lowercase letter and 1 special character. |
| `HighlightPortal.scaSamSecret` | SCA SAM secret |
| `HighlightPortal.license.key0` ... `key11` | Values from your Highlight license file |

Generate random secrets, for example with `openssl rand -base64 32 | tr -d '/+='`.

**Special characters in passwords.** Every value reaches the containers unescaped, as an env var from
the Secret. Postgres role passwords are quoted by psql itself (`\getenv` + `:'var'` in `init-db.sh`),
and cvedb reads its values through `${CVEDB_*}` placeholders in `cvedb.properties`, so no `\`
escaping is needed there any more. The remaining pitfalls are:

- In the Postgres superuser password and the `Cvedb.*` values, avoid the sequence `${`. Spring
  resolves it as a placeholder in cvedb.
- [Util-SyncDbPasswords.bat](Util-SyncDbPasswords.bat) goes through cmd `echo` and a `'...'` SQL
  literal. If you use it, avoid `'`, `"`, `&`, `|`, `<`, `>`, `^` and `%` in the Postgres superuser
  password.
- In `Keycloak.smtp.password`, write a literal `\` as `\\`. The `hlkeycloak` entrypoint (up to
  1.0.6) injects the value into its JSON realm-import file with no JSON escaping, and a single `\`
  crashes Keycloak on start-up (`Unrecognized character escape`).
- Unlike docker compose `.env` files, a `$` does **not** need doubling in Helm values.

### Using an external Secret (`existingSecret`)

For customers who manage secrets in an external store (Azure Key Vault, AWS Secrets Manager, GCP
Secret Manager, HashiCorp Vault...), the chart can use a Kubernetes Secret it doesn't manage
instead of `values-secret.yaml`. The Secret is typically synced into the namespace by External
Secrets Operator, the Secrets Store CSI driver (with `secretObjects` sync) or Sealed Secrets.

1. Create the Secret in the release namespace **before** installing the chart, with these exact
   keys (plain values - Kubernetes base64-encodes them itself):

   | Key | Value | Required |
   |---|---|---|
   | `postgres-superuser-password` | `postgres` superuser (also cvedb's datasource password) | Yes |
   | `postgres-highlight-user-password` | `highlight` role | Yes |
   | `postgres-highlight-root-password` | `highlight_root` role (the portal connects as it) | Yes |
   | `cvedb-nist-api-key` | NIST NVD API key | Yes |
   | `portal-admin-password` | Initial Highlight admin password (realm password policy applies) | Yes |
   | `portal-sca-sam-secret` | SCA SAM secret | Yes |
   | `cvedb-smtp-password`, `portal-smtp-password` | SMTP passwords | Optional |
   | `portal-license-key0`, `-key5`, `-key6`, `-key7`, `-key8`, `-key9`, `-key10`, `-key11` | Highlight license values | Optional |
   | `keycloak-db-password` | `keycloak` role | If `Keycloak.enabled` |
   | `keycloak-bootstrap-admin-password` | Temporary bootstrap admin | If `Keycloak.enabled` |
   | `keycloak-permanent-admin-password` | Keycloak admin console account | If `Keycloak.enabled` |
   | `keycloak-admin-client-secret` | `highlight-admin` client secret | If `Keycloak.enabled` |
   | `keycloak-portal-client-secret` | `highlight-portal` client secret | If `Keycloak.enabled` |
   | `keycloak-webhook-secret` | Keycloak -> portal webhook secret | If `Keycloak.enabled` |
   | `keycloak-smtp-password` | Keycloak SMTP password | Optional |

   A missing required key keeps the pod in `CreateContainerConfigError`. A missing optional key
   leaves the value empty.

   For a quick test without an external store:

   ```bash
   kubectl create secret generic highlight-external-sec -n highlight \
     --from-literal=postgres-superuser-password='...' \
     --from-literal=postgres-highlight-user-password='...' \
     ...
   ```

2. Install with `--set existingSecret=<secret-name>` (or set it in your values override). Don't pass
   `values-secret.yaml`; its values are ignored and the chart creates no Secret of its own:

   ```bash
   helm upgrade --install highlight . -n highlight -f values.yaml --set existingSecret=highlight-external-sec
   ```

Pods read the Secret only when they start. After a rotation in the external store, restart the
workloads (`kubectl rollout restart deployment highlightportal keycloak cvedb -n highlight` and
`kubectl rollout restart statefulset postgres -n highlight`). Postgres and Keycloak apply some of
these values only on first start, so also follow
[Settings that apply only on first start](#settings-that-apply-only-on-first-start).

**Migrating an existing installation** to `existingSecret`: copy the current values from the
chart-managed Secret, so the passwords already stored in Postgres and Keycloak don't change:

```bash
kubectl get secret highlight-pwd-sec -n highlight -o yaml   # base64 values, same keys
```

### 3. Check the rendered output (optional)

```bash
helm lint . -f values.yaml -f values-secret.local.yaml
helm template highlight . -n highlight -f values.yaml -f values-secret.local.yaml > rendered.yaml
```

An unsupported `networking.type` fails the render immediately.

## Deploy on Kubernetes - Ingress (HTTPS, recommended)

These steps apply to AKS, EKS, GKE and on-prem clusters. The namespace and release name are both
`highlight` in these examples. Change them as needed.

### Step 1 - Install an NGINX ingress controller (skip if the cluster already has one)

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
```

Pick the variant for your platform:

```bash
# EKS - Network Load Balancer
helm install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"="nlb"

# AKS - public load balancer
helm install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz

# AKS - internal load balancer (private VNet only)
helm install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-internal"="true"

# GKE or on-prem
helm install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace
```

Without internet access, run `helm pull ingress-nginx/ingress-nginx --untar` on a connected machine
and install from the extracted folder.

If the AKS **application routing add-on** is already installed, skip this step and set
`networking.ingress.className=webapprouting.kubernetes.azure.com` instead.

Get the controller's external address:

```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller
```

### Step 2 - Create the DNS record

Point `gateway.host` (e.g. `highlight.mycompany.com`) at the `EXTERNAL-IP` from step 1: an A record
for an IP, or a CNAME for an AWS load balancer hostname. The name must also resolve from inside the
cluster (see [Networking and TLS](#networking-and-tls-ingress-and-route-modes)).

### Step 3 - Create the namespace and TLS secret

The chart references an existing TLS secret. It doesn't create one. The certificate must cover
`gateway.host` (as CN or SAN) and `fullchain.pem` must contain the leaf certificate followed by
the intermediates.

```bash
kubectl create namespace highlight
kubectl create secret tls tls-secret-cast \
  --cert=fullchain.pem --key=privkey.pem -n highlight
```

To get a Let's Encrypt wildcard certificate by hand:

```bash
sudo certbot certonly --manual --preferred-challenges dns -d "*.mycompany.com"
# -> /etc/letsencrypt/live/mycompany.com/{fullchain,privkey}.pem
```

**Using cert-manager instead:** add its annotation and keep a secret name for it to fill in:

```yaml
networking:
  ingress:
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-prod
    tls:
      enabled: true
      secretName: highlight-tls
```

### Step 4 - Install the chart

```bash
helm upgrade --install highlight . -n highlight --create-namespace \
  -f values.yaml -f values-secret.local.yaml \
  --set gateway.host=highlight.mycompany.com
# optional: --set storageClass.name=managed-csi
```

On Windows, [helm-install.bat](helm-install.bat) runs the same command with `values.yaml` and
`values-secret.yaml`. Edit it to point at your local secrets file.

### Step 5 - Wait for start-up

```bash
kubectl get pods -n highlight -w
```

The first start takes several minutes:

1. `postgres-0` initializes its data directory and runs `init-db.sh`.
2. `keycloak` imports the `hl-portal` realm, creates the permanent admin and deletes the bootstrap
   admin (30-60 seconds after Postgres is ready).
3. `cvedb` starts and begins importing the NIST CVE dataset in the background.
4. `highlightportal` stays in `Init:` until cvedb and Keycloak both answer, then starts.

Then continue with [Verify the deployment and first login](#verify-the-deployment-and-first-login).

## Deploy on Kubernetes - NodePort (HTTP, no ingress controller)

Use this mode for bare-metal or lab clusters without an ingress controller, DNS record or
certificate. Everything runs over plain HTTP.

```bash
helm upgrade --install highlight . -n highlight --create-namespace \
  -f values.yaml -f values-secret.local.yaml \
  --set networking.type=nodeport \
  --set gateway.host=<node-hostname-or-ip> \
  --set networking.nodeport.portalPort=30080 \
  --set networking.nodeport.keycloakPort=30081
# on-prem example: --set storageClass.name=local-path
```

- Portal: `http://<node>:30080`
- Keycloak: `http://<node>:30081/auth`

Notes:

- Both ports must be free and inside the cluster's NodePort range (default 30000-32767). To run
  several releases on one cluster, give each release its own pair of ports.
- `gateway.host` must be reachable from users' browsers **and** from inside the pods. The portal
  calls Keycloak on `http://<gateway.host>:<keycloakPort>/auth`.
- `gateway.protocol` and `gateway.port` are ignored in this mode. Keycloak doesn't trust
  `X-Forwarded-*` headers here (`KC_PROXY_HEADERS` is unset) because no proxy sits in front of it.

## Restricted security mode

For clusters that enforce the **restricted** Pod Security Standard (for example, a namespace
labelled `pod-security.kubernetes.io/enforce=restricted`) or similar Kyverno or Gatekeeper
policies, add:

```bash
--set RestrictedSecurityMode=true
```

This works with both `ingress` and `nodeport`. Every pod and container then gets:

- `runAsNonRoot`, `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false`,
  `capabilities.drop: [ALL]`
- `readOnlyRootFilesystem: true`, with every writable path backed by a PVC or an `emptyDir`.
  Keycloak runs from a writable copy of `/opt/keycloak`, made by the `copy-keycloak-home` init
  container.
- Fixed non-root UIDs and fsGroups: postgres `999`, keycloak `1000`, portal and cvedb `5000`
  (the `*.runAsUser` and `*.fsGroup` values). In this mode, Postgres runs directly as its
  `postgres` user instead of starting as root.
- CPU and memory limits on every container, including init containers (`InitContainerResources`).

## Deploy on OpenShift

OpenShift uses the `route` networking mode (the built-in HAProxy router, no NGINX ingress
controller) and the `openshift.enabled` switch, both set by
[values-openshift.yaml](values-openshift.yaml). The chart is compatible with the default
**restricted-v2** SCC. It needs no `anyuid` or `privileged` grant.

With `openshift.enabled=true`:

- Pods get no fixed UID, GID or fsGroup. OpenShift assigns them from the namespace range, and the
  `*.runAsUser` and `*.fsGroup` values are ignored.
- Containers get the restricted `securityContext` (non-root, RuntimeDefault seccomp, no privilege
  escalation, all capabilities dropped).
- cvedb and the portal get extra `emptyDir` mounts for the paths their image user owns, which the
  random UID can't write.
- The images must run under an arbitrary UID with supplemental group 0. The `6.0.1` images built
  from `hl-docker` meet this: their writable paths are owned by group 0 with `g=u` permissions.

### Step 1 - Log in and create the project

```bash
oc login https://api.<cluster-domain>:6443 -u <user>
oc new-project highlight
```

### Step 2 - Choose a hostname and certificate

| Option | `gateway.host` | Certificate |
|---|---|---|
| **A - cluster apps domain** | `highlight.apps.<cluster-domain>` | None to supply. The router's default wildcard certificate is used. |
| **B - custom hostname** | e.g. `highlight.mycompany.com` (DNS CNAME to the router, usually `*.apps.<cluster-domain>`) | Pass the PEM files at install time. Routes can't reference a Secret. |

The requirement from [Networking and TLS](#networking-and-tls-ingress-and-route-modes) still
applies: the portal's JVM must trust the certificate. Many clusters, including OpenShift Local/CRC,
ship a self-signed default router certificate. With those, use option B with a publicly trusted
certificate.

### Step 3 - Install

Option A, with the default router certificate:

```bash
helm upgrade --install highlight . -n highlight --create-namespace \
  -f values.yaml -f values-secret.local.yaml -f values-openshift.yaml \
  --set gateway.host=highlight.apps.<cluster-domain>
```

Option B, with a custom hostname and certificate:

```bash
helm upgrade --install highlight . -n highlight --create-namespace \
  -f values.yaml -f values-secret.local.yaml -f values-openshift.yaml \
  --set gateway.host=highlight.mycompany.com \
  --set-file networking.route.tls.certificate=fullchain.pem \
  --set-file networking.route.tls.key=privkey.pem
# optional: --set-file networking.route.tls.caCertificate=ca.pem
```

Keep `values-openshift.yaml` **after** `values.yaml` so that it overrides `networking.type` and
`openshift.enabled`. You can also set a StorageClass explicitly, e.g.
`--set storageClass.name=gp3-csi` (ROSA) or `managed-csi` (ARO).

TLS is edge-terminated at the router (`insecureEdgeTerminationPolicy: Redirect`, so HTTP redirects
to HTTPS). The router sends plain HTTP to the pods and sets `X-Forwarded-Proto`, which Keycloak
trusts (`KC_PROXY_HEADERS=xforwarded`). Add router settings, such as a longer timeout, under
`networking.route.annotations`:

```yaml
networking:
  route:
    annotations:
      haproxy.router.openshift.io/timeout: 300s
```

### Step 4 - Check

```bash
oc get pods -n highlight -w
oc get routes -n highlight
```

The `highlight-keycloak` (`/auth`) and `highlight-portal` (`/`) routes must both show the same
host.

## Verify the deployment and first login

```bash
kubectl get pods,svc,pvc -n highlight
kubectl get ingress -n highlight          # ingress mode
oc get routes -n highlight                # OpenShift
```

All pods should be `Running` and all four PVCs `Bound`. Then:

| What | URL | Credentials |
|---|---|---|
| Highlight portal | `https://<gateway.host>/` (NodePort mode: `http://<node>:<portalPort>/`) | `HighlightPortal.admin.mail` / `HighlightPortal.admin.password` |
| Keycloak admin console | `https://<gateway.host>/auth/admin/` (NodePort mode: `http://<node>:<keycloakPort>/auth/admin/`) | `Keycloak.permanentAdmin.user` / `Keycloak.permanentAdmin.password` |

The bootstrap admin (`bootstrap-admin`) exists only during the first Keycloak init. Always use the
permanent admin afterwards.

Useful log commands:

```bash
kubectl logs -n highlight deploy/keycloak -f
kubectl logs -n highlight deploy/highlightportal -f
kubectl logs -n highlight deploy/highlightportal -c wait-for-keycloak   # portal stuck in Init
kubectl logs -n highlight deploy/cvedb -f
kubectl logs -n highlight postgres-0
```

## Day-2 operations

### Upgrading or changing settings

Re-run the same `helm upgrade --install` command with the same values files. Deployments use the
`Recreate` strategy, so each component stops fully before its replacement starts, which avoids two
pods sharing a ReadWriteOnce volume. The portal and cvedb images use `pullPolicy: Always`, so a
restart also picks up a new build of the same tag.

A ConfigMap or Secret change doesn't restart pods by itself. After an upgrade that only changes values:

```bash
kubectl rollout restart deployment highlightportal keycloak cvedb -n highlight
kubectl rollout restart statefulset postgres -n highlight   # only if Postgres passwords changed
```

### Settings that apply only on first start

Some values are read only once, when their PVC is empty. Changing them later in the values files
has no effect on a running installation:

| Value | Applied by | Changing it later |
|---|---|---|
| Postgres passwords (`Postgres.*.password`, `Keycloak.database.password`) | Postgres initdb and `init-db.sh`, run against an empty `db-data-highlight` | Run `Util-SyncDbPasswords.bat` (or the commands below) after `helm upgrade` |
| Keycloak realm (clients, redirect URIs from `gateway.host`, SMTP, client secrets), admin users | Keycloak first-run init. The sentinel `/opt/keycloak/data/init/.initialized` on `keycloak-data` stops it from running again. | Update in the Keycloak admin console, or reset Keycloak (see below) |
| `HighlightPortal.admin.password` | Seeded into Keycloak once, during the portal's Keycloak configuration check | Change it in Highlight or Keycloak |

**Resync Postgres passwords** with the values currently deployed. This touches neither data nor
PVCs. The passwords come from the `postgres-0` pod's env vars, so restart it first if the Secret
changed since it started. It is what [Util-SyncDbPasswords.bat](Util-SyncDbPasswords.bat) does:

```bash
NS=highlight
PGPASS=$(kubectl exec -n $NS postgres-0 -- printenv POSTGRES_PASSWORD)
echo "ALTER ROLE postgres WITH PASSWORD '$PGPASS';" | kubectl exec -i -n $NS postgres-0 -- psql -U postgres -v ON_ERROR_STOP=1
kubectl exec -n $NS postgres-0 -- bash -c "grep -E 'getenv|CREATE USER' /docker-entrypoint-initdb.d/init-db.sh | sed 's/CREATE USER/ALTER USER/' | psql -U postgres -v ON_ERROR_STOP=1"
kubectl rollout restart deployment cvedb highlightportal keycloak -n $NS
```

### Changing the hostname

1. `helm upgrade` with the new `gateway.host`. In ingress mode, also update the DNS record and the
   TLS secret. On OpenShift, pass the new certificate. This updates `HL_ROOT_URL`,
   `HL_KEYCLOAK_ADMIN_URL`, `KC_HOSTNAME` and `APP_BASE_URL`.
2. The realm was imported with the old URL. In the Keycloak admin console (realm `hl-portal`, client
   `highlight-portal`), update **Valid redirect URIs**, **Web origins** and the root/home URLs to
   the new host. Otherwise logins fail with `Invalid parameter: redirect_uri`.
3. `kubectl rollout restart deployment highlightportal keycloak -n highlight`.

### Resetting Keycloak only

This loses Keycloak users and configuration, including any SAML or IdP setup. Highlight data is
kept.

```bash
kubectl scale deployment keycloak highlightportal -n highlight --replicas=0
kubectl exec -n highlight postgres-0 -- psql -U postgres -c "DROP DATABASE keycloak;"
kubectl exec -n highlight postgres-0 -- psql -U postgres -c "CREATE DATABASE keycloak OWNER keycloak;"
kubectl exec -n highlight postgres-0 -- psql -U postgres -d keycloak -c "CREATE SCHEMA keycloak AUTHORIZATION keycloak;"
kubectl delete pvc keycloak-data -n highlight
helm upgrade --install highlight . -n highlight -f values.yaml -f values-secret.local.yaml   # recreates the PVC
kubectl scale deployment keycloak highlightportal -n highlight --replicas=1
```

The last `helm upgrade` must use the same flags as the original install, including `--set` and
`-f values-openshift.yaml`.

### Backing up the database

```bash
kubectl exec -n highlight postgres-0 -- pg_dumpall -U postgres | gzip > highlight-$(date +%F).sql.gz
```

Snapshots of the `db-data-highlight` volume, through your cloud provider or Velero, also work.
Include `highlightportal-config` (SAML SP configuration) in the backup.

## Uninstall and data cleanup

```bash
helm uninstall highlight -n highlight        # or helm-delete.bat
```

This removes every workload, Service, ConfigMap, Ingress and Route. The **PVCs are kept** because of
`helm.sh/resource-policy: keep`, and a reinstall reuses the existing data.

To delete **all data** permanently:

```bash
kubectl delete pvc db-data-highlight tmp-highlight highlightportal-config keycloak-data \
  -n highlight --ignore-not-found
kubectl delete namespace highlight           # optional; also removes the TLS secret
```

[Util-DeleteStorage.bat](Util-DeleteStorage.bat) does the same after asking you to type the
namespace name. Depending on the StorageClass reclaim policy (most dynamic cloud classes use
`Delete`), the underlying disks (EBS, Azure Managed Disk, GCE Persistent Disk) are destroyed as
well. This can't be undone without a backup.

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| Pods `Pending` | Not enough memory on the nodes (see [Cluster capacity](#cluster-capacity)), or a PVC is not bound. Check with `kubectl describe pod` and `kubectl get pvc`, and set `storageClass.name` if the cluster has no default class. |
| Portal stuck in `Init:1/3` (`wait-for-cvedb`) | cvedb isn't answering yet. Check `kubectl logs deploy/cvedb`: common causes are a wrong Postgres password or a bad `datasource` setting. |
| Portal stuck in `Init:2/3` (`wait-for-keycloak`) | Keycloak isn't ready. Check its logs: the database connection, the realm import (`Unrecognized character escape` means an unescaped `\` in `Keycloak.smtp.password`) or volume permissions. |
| Keycloak: `Failed to save truststore ... Permission denied` | `keycloak-data` isn't writable. Keep `Keycloak.fsGroup` set to a non-zero GID (default `1000`). |
| Portal starts with no Spring profile / `DatabaseManager` fails | `/tmp/.hl-envfile` couldn't be written to `tmp-highlight`. Keep `HighlightPortal.fsGroup` at `5000`. |
| Every portal request redirects to `versionerror.html` | The portal started before Keycloak was reachable and is stuck in `KEYCLOAK_CHECK_CONFIGURATION`. Run `kubectl rollout restart deployment highlightportal`. |
| Login fails: `Invalid parameter: redirect_uri` | The client's registered redirect URI doesn't match `gateway.host`, for example after a hostname change. See [Changing the hostname](#changing-the-hostname). |
| Login works in the browser but portal logs show SSL/PKIX errors against `/auth` | The portal's JVM doesn't trust the gateway certificate. Use a publicly trusted certificate (see [Networking and TLS](#networking-and-tls-ingress-and-route-modes)). |
| Portal can't reach `https://<gateway.host>/auth` from inside the cluster (timeouts) | DNS resolution or load-balancer hairpinning from inside the cluster. Make `gateway.host` resolve internally to the ingress controller, for example with an internal load balancer or a split-horizon DNS record. |
| cvedb, keycloak or the portal fail DB authentication after a reinstall | The kept PVC still holds the old passwords. See [Resync Postgres passwords](#settings-that-apply-only-on-first-start). |
| Keycloak logs JGroups/JOIN timeouts | Only expected with `KeycloakReplicaCount > 1`. With 1 replica, the chart sets `KC_CACHE=local`. |
| cvedb import errors about `cvedb.reference.url` length | Workaround: `kubectl exec -n highlight postgres-0 -- psql -U postgres -d highlight -c "ALTER TABLE cvedb.reference ALTER COLUMN url TYPE text;"` |
| `networking.type "..." is not supported` at install | Use one of `ingress`, `nodeport` or `route`. |

## Values reference

The most commonly changed values. See [values.yaml](values.yaml) for the full list, with inline
explanations.

| Key | Default | Description |
|---|---|---|
| `gateway.host` | `highlight.example.com` | External hostname (NodePort mode: the node hostname or IP) |
| `gateway.protocol` | `https` | `http` or `https` (ingress and route only) |
| `gateway.port` | `""` | Non-standard external port, if any (ingress and route only) |
| `networking.type` | `ingress` | `ingress`, `nodeport` or `route` |
| `networking.ingress.className` | `nginx` | IngressClass |
| `networking.ingress.annotations` | `{}` | Extra Ingress annotations (cert-manager, proxy sizes, and so on) |
| `networking.ingress.tls.enabled` / `.secretName` | `true` / `tls-secret-cast` | TLS on the Ingress, with an existing secret |
| `networking.nodeport.portalPort` / `.keycloakPort` | `30080` / `30081` | NodePorts |
| `networking.route.tls.enabled` | `true` | Edge TLS on OpenShift Routes |
| `networking.route.tls.certificate` / `.key` / `.caCertificate` | `""` | Custom Route certificate (PEM, via `--set-file`) |
| `networking.route.annotations` | `{}` | Extra Route annotations |
| `openshift.enabled` | `false` | OpenShift restricted-v2 SCC compatibility |
| `RestrictedSecurityMode` | `false` | Restricted Pod Security Standard, read-only root filesystem, fixed non-root UIDs |
| `existingSecret` | `""` | Name of an externally managed Secret holding every password/secret/license key. Empty means the chart creates `highlight-pwd-sec` from `values-secret.yaml` (see [Using an external Secret](#using-an-external-secret-existingsecret)) |
| `storageClass.name` | `""` | StorageClass (empty means the cluster default) |
| `storageClass.postgresSize` / `portalTmpSize` / `portalConfigSize` / `keycloakSize` | `50Gi` / `5Gi` / `100Mi` / `1Gi` | PVC sizes |
| `*ReplicaCount` | `1` | Replicas per component. Keep postgres, the portal and cvedb at 1. |
| `PostgresImage`, `HighlightPortalImage`, `CvedbImage`, `KeycloakImage`, `InitUtilImage` | see top of page | `name`, `tag`, `pullPolicy` for each image |
| `PostgresResources`, `HighlightPortalResources`, `CvedbResources`, `KeycloakResources`, `InitContainerResources` | see [Cluster capacity](#cluster-capacity) | Requests and limits |
| `Keycloak.enabled` | `true` | Deploy Keycloak (required for authentication in 6.x) |
| `Keycloak.realmName` | `hl-portal` | Don't change (see [Configuration](#1-non-secret-values-valuesyaml-or-your-override)) |
| `Keycloak.webhookPath` | `/WS2/public/keycloak-events` | Portal endpoint that receives Keycloak events |
| `Keycloak.fsGroup`, `HighlightPortal.fsGroup` | `1000`, `5000` | Volume GIDs (ignored on OpenShift) |
| `*.runAsUser`, `Postgres.fsGroup` | `999` / `1000` / `5000` | UIDs and GIDs used by `RestrictedSecurityMode` on plain Kubernetes |
