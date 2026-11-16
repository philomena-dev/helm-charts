# Philomena Helm charts

Helm charts for running [Philomena](https://github.com/philomena-dev/philomena),
the imageboard software behind Derpibooru and Furbooru, on Kubernetes.

| Chart | Description |
| :---- | :---------- |
| [philomena](charts/philomena/) | The whole site: app, web server, worker, media processor, migrations and scheduled tasks, with PostgreSQL, OpenSearch and Valkey bundled or brought along |
| [infisical-secret](charts/infisical-secret/) | Syncs Infisical folders into Kubernetes Secrets; an optional dependency of the philomena chart |

```bash
helm repo add philomena https://charts.philomena.dev
helm repo update
```

The rest of this file is a deployment guide. The chart's
[README](charts/philomena/README.md) is the reference for every value, and
[`examples/`](examples/) has values files to start from.

**Contents**

- [Deploying Philomena on Kubernetes](#deploying-philomena-on-kubernetes)
- [Running the site](#running-the-site): upgrades, maintenance, tasks, backups
- [Moving an existing site](#moving-an-existing-site)
- [Argo CD](#argo-cd)
- [Notes for k3s](#notes-for-k3s) and [other distributions](#notes-for-other-distributions)
- [Troubleshooting](#troubleshooting)
- [Working on the charts](#working-on-the-charts)
- [License](#license)

## Deploying Philomena on Kubernetes

### What you need

In the cluster:

- Kubernetes 1.27 or newer (1.29 for the public dump) and Helm 3 or 4.
- A default StorageClass, for the database and the search index.
- A way in from the internet: an ingress controller, a Gateway API
  implementation or a LoadBalancer.
- Room for it. The defaults request about 2 CPUs and 5 GiB of memory and fit
  a small site on a node with 8 GB; the limits allow bursts to several times
  that. See [Sizing](#sizing).

Outside the cluster:

- An S3-compatible bucket for uploaded files (Cloudflare R2, Backblaze B2,
  AWS S3, MinIO, ...) and an access key for it. Philomena stores every
  upload there; nothing is kept on a volume.
- Two host names: one for the site and one for the files (the "CDN" domain),
  for example `philomena.example` and `cdn.philomena.example`.
- An SMTP account for outgoing mail, and [hCaptcha](https://www.hcaptcha.com/)
  keys. Philomena refuses to start without either.

### 1. Prepare the cluster

**PostgreSQL operator.** The chart's bundled database is a
[CloudNativePG](https://cloudnative-pg.io/) cluster, which needs the operator:

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system --create-namespace --wait
```

Skip this if you bring your own PostgreSQL
([External services](#external-services)).

**OpenSearch kernel setting.** OpenSearch does not start unless
`vm.max_map_count` is at least 262144 on the node it runs on. Many current
distributions already default to more; check with `sysctl vm.max_map_count`
and raise it if needed:

```bash
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-opensearch.conf
sudo sysctl --system
```

Where you cannot reach the nodes, let the OpenSearch subchart set it with a
privileged init container instead (`opensearch.sysctlInit.enabled: true` in
your values).

**TLS.** The chart serves plain HTTP inside the cluster and leaves TLS to
the Ingress or Gateway. With [cert-manager](https://cert-manager.io/docs/installation/helm/)
and a `ClusterIssuer`, one annotation on the Ingress gets you certificates
(step 3). If TLS ends at a proxy or CDN in front of the cluster, nothing is
needed here.

### 2. Create the namespace and the configuration Secret

Philomena reads its configuration from environment variables. The chart
fills in the ones that point at the database, OpenSearch, Valkey and
mediaproc; the rest (secrets, domains, S3, SMTP) come from one Secret.

Copy [`examples/philomena.env`](examples/philomena.env), fill it in, and
keep it somewhere safe: it is the source of truth for the site's secrets.

```bash
curl -LO https://raw.githubusercontent.com/philomena-dev/helm-charts/main/examples/philomena.env
$EDITOR philomena.env

kubectl create namespace philomena
kubectl -n philomena create secret generic philomena-env --from-env-file=philomena.env
```

What matters most in there:

- The four secrets (`SECRET_KEY_BASE`, `PASSWORD_PEPPER`, `OTP_SECRET_KEY`,
  `ANONYMOUS_NAME_SALT`): `openssl rand -hex 64` each, never changed again.
- `ADMIN_EMAIL` and `ADMIN_PASSWORD`, the first administrator. **Choose a
  real password.** It is checked against known breaches, and the first
  install fails with upstream's default.
- `APP_ORIGIN` and `SITE_DOMAINS`: the site's public URL and every host
  name it answers on.
- `CDN_HOST` and the `*_URL_ROOT` variables: where browsers load uploaded
  files from.
- The `S3_*` and `AWS_*` variables for the bucket.

Do not add `MIX_ENV`, `DATABASE_URL`, `REDIS_HOST`, `OPENSEARCH_URL` or
`MEDIAPROC_ADDR`; the template explains why. To change a variable later,
recreate the Secret and restart the workloads:

```bash
kubectl -n philomena create secret generic philomena-env --from-env-file=philomena.env \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n philomena rollout restart deployment/philomena deployment/philomena-worker
```

If your secrets live in Infisical, the chart can sync the Secret for you
instead; see [`infisical-secret`](charts/infisical-secret/).

### 3. Write your values

Start from [`examples/minimal.yaml`](examples/minimal.yaml):

```yaml
existingSecret: philomena-env

ingress:
  enabled: true
  className: traefik
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
  hosts:
    - host: philomena.example
    - host: cdn.philomena.example
  tls:
    - secretName: philomena-tls
      hosts:
        - philomena.example
        - cdn.philomena.example

web:
  # Serve the CDN domain from the S3 bucket
  cdn:
    enabled: true
    hosts:
      - cdn.philomena.example
  # Who may tell the site what the visitor's IP address is
  trustedProxies:
    - 10.42.0.0/16
  clientIpHeaders:
    - X-Forwarded-For
```

Three decisions hide in there.

**How the site is reached.** `ingress` creates an Ingress for any
controller; `ingress.className` picks it. With the Gateway API, use
`httpRoute` instead (`parentRefs`, `hostnames`). Without either, set
`service.type` to `LoadBalancer` or `NodePort` and put your own proxy in
front. Uploads can be large (`web.maxBodySize`, 130 MiB by default), so check
your controller's request body and read timeout limits.

**Who serves the uploaded files.** Browsers load images from `CDN_HOST`,
and something has to translate those URLs into objects in the bucket.
`web.cdn.enabled` makes the site's own web server do it, which is the
simplest setup and what the example uses: add the CDN host to `web.cdn.hosts`
and to the Ingress. Large sites keep image traffic away from the app pods by
serving that domain from a caching proxy or CDN outside the cluster; they
leave `web.cdn` off.

**Whose word is taken for the visitor's IP address.** Bans and rate limits
depend on it. The web server believes the headers in `web.clientIpHeaders`
only when a request comes from `web.trustedProxies`. Set the latter to where
your ingress controller's requests come from, usually the pod network
(`10.42.0.0/16` on k3s, `10.244.0.0/16` with flannel elsewhere): the default
trusts every private address, which lets any pod in the cluster pose as any
visitor. Behind Cloudflare, keep the default headers (`CF-Connecting-IP`
first) and make sure only Cloudflare can reach your ingress; otherwise list
`X-Forwarded-For` alone.

Your ingress controller has to pass the real client address on, too. If
every visitor shows up with the same address, see
[Troubleshooting](#troubleshooting).

### 4. Install

```bash
helm install philomena philomena/philomena \
  --namespace philomena \
  --values values.yaml \
  --timeout 30m
```

The release name becomes the prefix of every resource; the commands in this
guide assume `philomena`.

Helm creates the database, OpenSearch, Valkey and the workloads, then waits
for the `setup-production` Job, which loads the schema, creates the
administrator and builds the search indexes. The app and worker restart a
few times until it is done; that is expected on the first install. Watch it
with:

```bash
kubectl -n philomena get pods -w
kubectl -n philomena logs -f job/philomena-setup-production
```

When everything is `Running`, open the site and log in with `ADMIN_EMAIL`
and `ADMIN_PASSWORD`. Then remove `ADMIN_PASSWORD` from your env file; it
is not read again.

To look at the site before DNS and TLS are in place:

```bash
kubectl -n philomena port-forward svc/philomena 8080:80
```

Philomena builds its URLs from `APP_ORIGIN` and loads images from
`CDN_HOST`, so a port-forward is only good for a first look.

### External services

Each bundled service has a switch, and an `external*` block to point the
app at one you run elsewhere. On a cluster without the CloudNativePG
operator:

```yaml
postgresql:
  enabled: false
externalDatabase:
  host: postgres.example.com
  database: philomena
  existingSecret: philomena-db  # "username" and "password" keys
```

`valkey.enabled: false` with `externalValkey.host`, and `opensearch.enabled:
false` with `externalOpensearch.url`, work the same way;
[`examples/external-services.yaml`](examples/external-services.yaml) has all
of them, and the chart README says what each service has to look like
([database](charts/philomena/README.md#external-database), ICU locale
included).

### Sizing

The defaults are for trying the chart out and for small sites. For anything
bigger, start from [`examples/production.yaml`](examples/production.yaml),
which carries the numbers of a real site, and adjust:

| Component | What drives it |
| :-------- | :------------- |
| OpenSearch | Index size. Give the JVM half of the container's memory (`opensearch.opensearchJavaOpts`), the rest is page cache. Requests equal to limits keep it from being evicted first. |
| PostgreSQL | Database size and connections: `shared_buffers` at about a quarter of the memory limit, `max_connections` above the sum of all pools. |
| mediaproc | Uploads. Transcoding bursts to whatever the limits allow; large sites give it 8 to 16 CPUs and 16 to 24 GiB. |
| Setup Job | The search index build runs one batch per CPU of its limit. Raise `setupJob.resources` before the first run against a big database. |
| App, worker | Traffic. The Erlang VM starts one scheduler per CPU of the limit. |

## Running the site

### Upgrading to a new Philomena release

The three Philomena images share one version. Change it in one place:

```yaml
image:
  tag: "1.3.1"
```

```bash
helm repo update
helm upgrade philomena philomena/philomena \
  --namespace philomena --values values.yaml --timeout 1h
```

Before anything changes, the preflight Job checks whether the database can
be upgraded to that release; if a release needs a decision from you, the
upgrade stops there and the Job's log says which variable to pass through
`setupJob.extraEnv`. Then the setup Job migrates the database and the search
indexes, and only then do the new app, worker and mediaproc roll out.

- Helm waits for the migration within `--timeout`. Be generous: a timeout
  fails the upgrade but does not stop the Job.
- Releases that convert data ("release migrations", see the release notes)
  want the site stopped while they run. The Jobs run before Helm touches the
  workloads, so that takes two upgrades: one that stops the version that is
  running, and one that moves to the new version and starts it again after
  the migration.

  ```bash
  # 1. image.tag still names the running version
  helm upgrade philomena philomena/philomena -n philomena --values values.yaml \
    --set replicaCount=0 --set worker.replicaCount=0 --set cron.suspend=true
  # 2. after changing image.tag in values.yaml
  helm upgrade philomena philomena/philomena -n philomena --values values.yaml --timeout 3h
  ```

- A rollback (`helm rollback`, or the old tag) brings back the old
  workloads, not the old database. Have a backup, or a
  [restore point](#backups), before a release that migrates.

New chart versions are upgraded the same way; read the chart's release
notes first.

### Maintenance page

```bash
helm upgrade philomena philomena/philomena -n philomena --values values.yaml --set web.downtime=true
```

Every request gets the downtime page with a 503 until you upgrade again
without it.

### Logs, shells and one-off tasks

```bash
kubectl -n philomena logs -f deploy/philomena -c philomena   # app
kubectl -n philomena logs -f deploy/philomena -c web         # web server (access log)
kubectl -n philomena logs -f deploy/philomena-worker
kubectl -n philomena logs -f deploy/philomena-mediaproc
kubectl -n philomena rollout restart deploy/philomena deploy/philomena-worker

# IEx attached to the running app
kubectl -n philomena exec -it deploy/philomena -c philomena -- \
  env RELEASE_NODE=philomena_app_0 philomena remote

# psql as superuser, in the database pod
kubectl -n philomena exec -it philomena-postgresql-1 -c postgres -- psql -U postgres philomena
```

Anything that takes longer than a shell session should live, or has to run
while the app is scaled down, goes into a Job.
[`scripts/philomena-task.sh`](scripts/philomena-task.sh) starts one with the
app's image and environment:

```bash
# State of the search indexes
scripts/philomena-task.sh search-status philomena eval 'Philomena.Release.search_status()'
# Create or upgrade the search indexes and fill them from the database
TASK_CPU=8 TASK_MEMORY=8Gi \
  scripts/philomena-task.sh reindex philomena eval 'Philomena.Release.migrate_search()'

kubectl -n philomena logs -f job/reindex
```

`philomena eval` does not start the application. The functions in
`Philomena.Release` do that themselves; anything else needs
`Application.ensure_all_started(:philomena);` in front.

### Backups

What needs backing up is the database and your env file. Uploaded files are
in your bucket (give it versioning or a second bucket via the `ALT_S3_*`
variables), and the search index is rebuilt from the database.

The bundled database can archive its WAL continuously and take scheduled
base backups to S3, which gives you point-in-time recovery. It uses
CloudNativePG's Barman Cloud plugin, which needs cert-manager:

```bash
helm upgrade --install plugin-barman-cloud cnpg/plugin-barman-cloud \
  --namespace cnpg-system --wait

kubectl -n philomena create secret generic philomena-backup-s3 \
  --from-literal=ACCESS_KEY_ID=... --from-literal=ACCESS_SECRET_KEY=...
```

Then add the `postgresql.backups` block from
[`examples/production.yaml`](examples/production.yaml) to your values and
upgrade. In that order: the plugin has to be running and the Secret has to
exist first, or the first backup fails and archiving stalls until they do.
Check on it with:

```bash
kubectl -n philomena get backups.postgresql.cnpg.io
kubectl -n philomena get cluster philomena-postgresql \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
```

Once the first base backup has completed and the archiver has caught up,
turn on `setupJob.restorePoint.enabled`. Every upgrade then creates a named
restore point right before it migrates and refuses to migrate if the archive
is not working, so each release can be undone
([how](charts/philomena/README.md#restore-point-before-migrating)).

After a big import or migration the archiver can be hours behind; raise
`postgresql.backups.wal.maxParallel` if it does not keep up, and keep an eye
on the database volume, which holds the WAL until it is shipped.

### Public database dump

The chart can publish a nightly anonymized dump of the database to a bucket,
together with a page to download it from, like the ones Derpibooru and
Furbooru offer. It is off by default; see
[Public dump](charts/philomena/README.md#public-dump).

## Moving an existing site

To move a site from another server (upstream's Docker setup, for instance)
into the cluster, restore its database before Philomena first touches the
new one.

1. On the old server, stop the site and dump the database without owners:
   `pg_dump -Fc -O -f philomena.pgdump philomena`. Note its locale
   (`psql -l`); the new database has to match it, see
   `postgresql.cluster.initdb` in the chart's values.
2. Create the env Secret from the old `.env`, minus `MIX_ENV`,
   `DATABASE_URL`, `PG*`, `REDIS_HOST`, `OPENSEARCH_URL`, `MEDIAPROC_ADDR`
   and anything else that names hosts of the old setup. Philomena 1.3 also
   needs `APP_ORIGIN`, which older setups do not have.
3. Install the chart with the services only:

   ```bash
   helm install philomena philomena/philomena -n philomena --values values.yaml \
     --set setupJob.enabled=false --set cron.suspend=true \
     --set replicaCount=0 --set worker.replicaCount=0
   kubectl -n philomena get cluster philomena-postgresql -w   # until "Cluster in healthy state"
   ```

4. Restore the dump into the empty database, as the superuser, with the app
   role as owner:

   ```bash
   POD=philomena-postgresql-1
   kubectl -n philomena cp philomena.pgdump $POD:/var/lib/postgresql/data/restore.pgdump -c postgres
   kubectl -n philomena exec $POD -c postgres -- \
     pg_restore -U postgres --role=philomena -O -j 8 -d philomena /var/lib/postgresql/data/restore.pgdump
   kubectl -n philomena exec $POD -c postgres -- psql -U postgres -d philomena -c 'ANALYZE;'
   kubectl -n philomena exec $POD -c postgres -- rm /var/lib/postgresql/data/restore.pgdump
   ```

5. Upgrade with your normal values. The preflight Job checks the restored
   database, the setup Job migrates it to the release you are installing and
   builds the search indexes from scratch, then the site starts:

   ```bash
   helm upgrade philomena philomena/philomena -n philomena --values values.yaml --timeout 6h
   ```

Step 5 is the long one on a large site: give `setupJob.resources` plenty of
CPU for it (see [Sizing](#sizing)), and enable backups only afterwards or
with a high `wal.maxParallel`, because a restore and a full migration
produce a lot of WAL. If the dump comes from a release older than the one
you install, read that release's upgrade notes first; rehearse the whole
thing on a copy before the real move.

## Argo CD

The chart works as an Argo CD Application without special handling;
[`examples/argocd-application.yaml`](examples/argocd-application.yaml) is a
complete one. What to know:

- The preflight and setup Jobs are Argo CD `Sync` hooks in waves 1 and 2;
  the database and OpenSearch come first (wave 0) and the workloads last
  (wave 3). They run in every sync, first install included, and a sync
  fails when one of them does.
- Use `ServerSideApply=true`, and the
  `argocd.argoproj.io/compare-options: ServerSideDiff=true` annotation on
  the Application; without the latter the OpenSearch StatefulSet is reported
  as out of sync forever.
- With `postgresql.backups`, set `postgresql.backups.objectStore.helmHook:
  false`, so that the object store definition is an ordinary resource of
  the Application instead of a Helm hook, which Argo CD treats as
  ephemeral.
- Think twice before automated sync, pruning and the resources finalizer:
  a deploy runs migrations, and deleting the Application should never take
  the database with it.
- To stop the site for a release migration, sync twice: first the running
  version with `replicaCount: 0`, `worker.replicaCount: 0` and
  `cron.suspend: true`, then the new `image.tag` without those three. The
  second sync migrates before it starts the workloads again.

## Notes for k3s

[k3s](https://k3s.io/) brings most of what the chart needs: Traefik as the
ingress controller, ServiceLB, the `local-path` StorageClass as default and
NetworkPolicy enforcement. The CloudNativePG operator is the only thing to
install. A few specifics:

- **kubeconfig.** Helm needs `export KUBECONFIG=/etc/rancher/k3s/k3s.yaml`
  on the server (or a copy of that file elsewhere).
- **Ingress.** Use `ingress.className: traefik`.
- **Pod network.** It is `10.42.0.0/16` unless you changed `--cluster-cidr`;
  that is the value for `web.trustedProxies`.
- **Client addresses and uploads.** Out of the box, Traefik behind ServiceLB
  typically sees a cluster address instead of the visitor's, and Traefik 3
  gives a request 60 seconds to arrive in full, which a large upload on a
  slow line exceeds. Both are settings of the bundled Traefik, changed
  through a `HelmChartConfig` in `/var/lib/rancher/k3s/server/manifests/`
  (check the names against the Traefik chart your k3s ships):

  ```yaml
  apiVersion: helm.cattle.io/v1
  kind: HelmChartConfig
  metadata:
    name: traefik
    namespace: kube-system
  spec:
    valuesContent: |-
      service:
        spec:
          externalTrafficPolicy: Local
      ports:
        websecure:
          transport:
            respondingTimeouts:
              readTimeout: 30m
  ```

  If a proxy or CDN sits in front of the node, Traefik also has to trust
  its forwarded headers (`ports.websecure.forwardedHeaders.trustedIPs`).
- **`vm.max_map_count`.** Set it on the host as in step 1.
- **Storage.** `local-path` volumes are directories on the node
  (`/var/lib/rancher/k3s/storage`). Their size is not enforced, they do not
  move with a pod to another node, and deleting the claim deletes the data.
  That is fine for a single-node site with off-site
  [backups](#backups); for more nodes, pin the database and OpenSearch with
  the subcharts' affinity values or use a replicated StorageClass.
- **Public dump.** Its scratch volume is an ephemeral claim on the default
  StorageClass, so it lands on the same disk as the database unless you
  give it another class (`publicDump.scratch.storageClass`).
- **Pod security.** k3s does not enforce Pod Security Standards by default.
  If you turn them on, the namespace needs `baseline`
  ([why](charts/philomena/README.md#security)).

## Notes for other distributions

- **kubeadm and other bare clusters** come without the parts k3s bundles:
  you need a CNI, a StorageClass (for one node,
  [local-path-provisioner](https://github.com/rancher/local-path-provisioner)
  is enough), an ingress controller or Gateway, and something that gives it
  an address (a cloud load balancer, MetalLB, or host ports).
- **Talos** additionally enforces the `baseline` Pod Security Standard on
  every namespace by default. The chart
  runs under it, but storage provisioners and host-network ingress
  controllers need their namespaces labelled `privileged`. Sysctls such as
  `vm.max_map_count` belong in the machine configuration, and there is no
  StorageClass until you install one.
- **Flannel** on its own (Talos's default CNI) does not enforce
  NetworkPolicies, so `networkPolicy.enabled` has no effect there.
- **Managed clusters** usually have a StorageClass and load balancers
  already. Check that the nodes allow the `vm.max_map_count` change, or use
  `opensearch.sysctlInit.enabled`.
- **Process limits.** mediaproc starts many processes and threads while it
  transcodes. Where the kubelet caps them (`podPidsLimit`), make the cap
  generous; Kubernetes has no per-workload setting for it.

## Troubleshooting

**`no matches for kind "Cluster" in version "postgresql.cnpg.io/v1"`** on
install. The CloudNativePG operator is missing: install it (step 1), or set
`postgresql.enabled: false` and use an external database.

**The setup Job fails with `password: {"has been compromised in a data
breach", []}`.** `ADMIN_PASSWORD` is missing or too common (step 2). The
database is left half set up, and the next run would skip the rest, so
empty it before trying again:

```bash
kubectl -n philomena exec philomena-postgresql-1 -c postgres -- psql -U postgres -d philomena \
  -c 'DROP SCHEMA public CASCADE' -c 'CREATE SCHEMA public AUTHORIZATION philomena'
helm upgrade philomena philomena/philomena -n philomena --values values.yaml --timeout 30m
```

The same reset applies to any failure of the very first setup run. Never run
it against a database that holds a site.

**Pods crash with `could not fetch environment variable "..."`.** That
variable is missing from the env Secret. The setup Job fails the same way.

**Pods stay in `CreateContainerConfigError`.** A Secret they reference does
not exist: the env Secret (step 2), or `philomena-postgresql-app`, which
CloudNativePG creates once the database is up (wait a moment).

**OpenSearch restarts with `max virtual memory areas vm.max_map_count
[65530] is too low`.** See step 1.

**`helm upgrade` fails with a timeout while the setup Job is still
running.** The Job carries on. Wait for it
(`kubectl -n philomena logs -f job/philomena-setup-production`), then run
the upgrade again with a longer `--timeout`; the second run finds the
database migrated and finishes quickly.

**`helm upgrade` fails with `conflict with "kubectl-patch"`** (or
`kubectl-edit`, or another tool's name). Helm 4 applies server-side, and a
field of a chart resource was changed by hand since, so it now has a second
owner. Decide whose value should stand; to take the field back for the
chart, run the upgrade once with `--force-conflicts`. To pause the site, use
values (`replicaCount`, `cron.suspend`, `web.downtime`) rather than
`kubectl patch`.

**Every visitor has the same IP address, or everyone is rate limited at
once.** The site sees your ingress controller instead of the visitors.
Check, in this order: that the controller itself sees real addresses
(`externalTrafficPolicy: Local` on its Service, or PROXY protocol or trusted
forwarded headers if something sits in front of it), that
`web.trustedProxies` covers the address the controller connects from, and
that `web.clientIpHeaders` names a header it sets. The web server's access
log shows both `remote_ip` and the `client_ip` it settled on.

**Images do not load.** Open one of the image URLs directly. A DNS or TLS
error means the CDN host is missing from the Ingress; a 404 from the web
server means `web.cdn` is off, the host is not in `web.cdn.hosts`, or the
`*_URL_ROOT` and `*_FILE_ROOT` variables do not follow
[`examples/philomena.env`](examples/philomena.env).

**Large uploads fail.** Something in front of the site limits the request
size or time: the ingress controller (see the [k3s notes](#notes-for-k3s)
for Traefik), a CDN's upload limit, or `web.maxBodySize`.

**The search index build is slow.** It runs one batch per CPU of
`setupJob.resources.limits.cpu`, and the number is fixed when the Job
starts. Raise it for the next run.

## Working on the charts

```bash
helm dependency build charts/philomena   # fetch the subcharts (not committed)
helm lint charts/philomena
helm template philomena charts/philomena --values charts/philomena/ci/full-values.yaml

ct lint --config ct.yaml                 # what CI runs on pull requests
scripts/validate.sh                      # kubeconform, CRDs included
```

`ct lint` wants the `version` in `Chart.yaml` raised with every change to a
chart. Each chart has `ci/*-values.yaml` files that exercise its optional
paths; add to them when you add a value, and keep `values.schema.json` and
the README's values table in step.

The public dump's scripts, SQL and page template
(`charts/philomena/files/public-dump*`, `index.html.tmpl`) are maintained in
the philomena-public-dump repository, where they are tested against a real
database. Change them there and copy them over with
`scripts/sync-public-dump.sh`.

Pushing to `main` releases every chart version that has no
`<chart>-<version>` GitHub release yet and republishes
<https://charts.philomena.dev> ([`release.yaml`](.github/workflows/release.yaml)).
The releases are the store of record: the workflow packages the new version
and attaches it to a release, then rebuilds the whole site from the packages
of all releases, with a fresh `index.yaml` and the landing page, and deploys
it to GitHub Pages. Running it again repairs a failed run.

The landing page is [`site/index.html.tmpl`](site/index.html.tmpl), styled
with [PhilomenaCSS](https://github.com/Meow/PhilomenaCSS) (pinned in
`site/package.json`) and filled in by `scripts/build-site.py`. To preview it:

```bash
npm ci --prefix site
mkdir -p _site
helm package charts/* --dependency-update --destination _site
helm repo index _site --url https://charts.philomena.dev
python3 scripts/build-site.py --site _site \
  --repo-url https://charts.philomena.dev \
  --source-url https://github.com/philomena-dev/helm-charts
open _site/index.html
```

## License

The charts are released under the [MIT License](LICENSE). Philomena itself
is licensed separately, under the AGPL-3.0.
