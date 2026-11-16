# philomena

Deploys the [Philomena](https://github.com/philomena-dev/philomena)
imageboard on Kubernetes: the app with its Caddy web sidecar, the background
worker, the `mediaproc` media processor, the `setup-production` Jobs that
initialize and migrate the database and search indexes, the scheduled
maintenance CronJobs and, optionally, an anonymized public database dump.

The chart is written for Philomena 1.3 and newer. 1.2.x images do not work
with it.

This file is the reference for the chart's values and behavior. For a
walkthrough from an empty cluster to a running site, see the
[deployment guide](https://github.com/philomena-dev/helm-charts#deploying-philomena-on-kubernetes)
in the repository README.

```bash
helm repo add philomena https://charts.philomena.dev
helm install philomena philomena/philomena \
  --namespace philomena --create-namespace \
  --set existingSecret=philomena-env \
  --timeout 30m
```

## What gets deployed

| Workload | Kind | Image | Notes |
| :------- | :--- | :---- | :---- |
| `<release>` | Deployment | `philomena` + `philomena-web` | The app on port 4000 and Caddy in front of it; the Service points at Caddy |
| `<release>-worker` | Deployment | `philomena` | Background jobs (`worker.enabled`) |
| `<release>-mediaproc` | Deployment | `mediaproc` | Media processing server (`mediaproc.enabled`) |
| `<release>-preflight`, `<release>-setup-production` | Job (hook) | `philomena` | Run on install and on every upgrade (`setupJob.*`) |
| `<release>-cron`, `<release>-cron-daily` | CronJob | `philomena` | Maintenance tasks (`cron.*`) |
| `<release>-public-dump` | CronJob | `postgres`, `rclone` | Off by default (`publicDump.*`) |

Backing services come from subcharts, each with an `enabled` switch and an
external alternative:

| Service | Subchart | Needs | External alternative | Injected as |
| :------ | :------- | :---- | :------------------- | :---------- |
| PostgreSQL | [CloudNativePG `cluster`](https://github.com/cloudnative-pg/charts/tree/main/charts/cluster) 0.9.0, aliased `postgresql` | the CNPG operator | `externalDatabase.*` | `DATABASE_URL`, `PG*` |
| OpenSearch | [`opensearch`](https://github.com/opensearch-project/helm-charts/tree/main/charts/opensearch) 3.9.0 | `vm.max_map_count` on the nodes | `externalOpensearch.url` | `OPENSEARCH_URL` |
| Valkey | [`valkey`](https://github.com/valkey-io/valkey-helm) 0.12.1 | | `externalValkey.host` | `REDIS_HOST` |
| Secrets sync | [`infisical-secret`](../infisical-secret/), aliased `infisical`, off by default | the Infisical operator | `existingSecret` | `envFrom` |

Everything under `postgresql`, `opensearch`, `valkey` and `infisical` is
passed to the subchart, so all of their options are available.

## Image version

Philomena is released as three images that move together. `image.tag` sets
the version of all of them and defaults to the chart's `appVersion`:

```yaml
image:
  tag: "1.3.1"
```

`web.image.tag` and `mediaproc.image.tag` are empty by default, which means
"same as `image.tag`"; set one only to run that component on a different
version. Each image also takes a `digest`, which wins over any tag. To run
your own builds, set the three `repository` values:

```yaml
image:
  repository: registry.example.com/booru/philomena
  tag: "1.3.1-mybooru"
web:
  image:
    repository: registry.example.com/booru/philomena-web
mediaproc:
  image:
    repository: registry.example.com/booru/mediaproc
```

The site's name, logo and theme are compiled into the `philomena` and
`philomena-web` images, so a site with its own branding builds its own from a
fork.

## App configuration

Philomena is configured through environment variables. The chart sets the
ones it knows the answer to:

| Variable | Set to |
| :------- | :----- |
| `PORT`, `APP_IP` | `4000`, `0.0.0.0` |
| `DATABASE_URL`, `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD` | the bundled or external database |
| `REDIS_HOST` | the bundled or external Valkey |
| `OPENSEARCH_URL` | the bundled or external OpenSearch |
| `MEDIAPROC_ADDR` | the bundled or external mediaproc |

Everything else comes from you, through any mix of:

- **`existingSecret`**: a Secret whose keys become environment variables of
  the app, worker, setup Jobs and cron jobs. This is where the secrets go.
  [`examples/philomena.env`](https://github.com/philomena-dev/helm-charts/blob/main/examples/philomena.env)
  is a commented template for it.
- **`infisical`**: the same Secret, synced from Infisical (`<release>-env`
  from `infisical.secrets.env`). `existingSecret` wins when both are set.
- **`env`**: a map of non-secret variables in the values.
- **`extraEnv`**: a list of `EnvVar`, for entries that need `valueFrom`.

`env` and `extraEnv` entries win over the same key in the Secret. Do not
repeat a name across `env`, `extraEnv` and the chart's own variables.

Philomena 1.3 does not start without these (see
[`config/runtime.exs`](https://github.com/philomena-dev/philomena/blob/master/config/runtime.exs)):
`SECRET_KEY_BASE`, `PASSWORD_PEPPER`, `OTP_SECRET_KEY`,
`ANONYMOUS_NAME_SALT`, `APP_ORIGIN`, `SITE_DOMAINS`, `CDN_HOST`,
`IMAGE_URL_ROOT`, `AVATAR_URL_ROOT`, `ADVERT_URL_ROOT`, `BADGE_URL_ROOT`,
`TAG_URL_ROOT`, `IMAGE_FILE_ROOT`, `AVATAR_FILE_ROOT`, `ADVERT_FILE_ROOT`,
`BADGE_FILE_ROOT`, `TAG_FILE_ROOT`, `S3_SCHEME`, `S3_HOST`, `S3_PORT`,
`S3_BUCKET`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `SMTP_RELAY`,
`SMTP_USERNAME`, `SMTP_PASSWORD`, `MAILER_ADDRESS`, `HCAPTCHA_SITE_KEY`,
`HCAPTCHA_SECRET_KEY` and `TUMBLR_API_KEY`.

Two things to keep out of the Secret:

- `MIX_ENV`. Several release migrations skip their data conversions when it
  is set, expecting them to be run by hand. The production image does not
  need it.
- The variables from the table above. An old `.env` that carries a
  `DATABASE_URL` is harmless (the chart's value wins), but confusing.

### First administrator

When `setup-production` initializes an empty database, it creates one
administrator from `ADMIN_USERNAME` (default `Administrator`), `ADMIN_EMAIL`
(default `admin@example.com`) and `ADMIN_PASSWORD`. The password is checked
against the Pwned Passwords database like any other, and the built-in default
is in it, so **the first install fails unless `ADMIN_PASSWORD` is set to a
password that has not been breached**. Put the three variables into the env
Secret or pass them to the setup Job only:

```yaml
setupJob:
  extraEnv:
    - name: ADMIN_EMAIL
      value: you@philomena.example
    - name: ADMIN_PASSWORD
      valueFrom:
        secretKeyRef:
          name: philomena-admin
          key: password
```

They are only read during that first run.

### Site configuration files

`siteConfig` replaces the JSON files that Philomena reads from its `config/`
directory (`avatar.json`, `footer.json`, `quick_tag_table.json`, `tag.json`),
without building an image for them:

```yaml
siteConfig:
  footer.json: |
    {
      "cols": ["Site"],
      "Site": [{"title": "Rules", "url": "/rules", "bold": true}]
    }
```

Start from the files in the
[Philomena source](https://github.com/philomena-dev/philomena/tree/master/config).
A file replaces the built-in one completely.

### CDN cache purging

When an image is hidden, deleted or replaced, the app calls
`/usr/local/bin/purge-cache '{"files":[...]}'` so that a caching CDN can drop
its copies. The script in the image does nothing. `purgeCache.script`
replaces it; it runs with the app's environment, so tokens can live in the
env Secret:

```yaml
purgeCache:
  script: |
    #!/bin/sh
    set -e
    wget -qO /dev/null \
      --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      --header "Content-Type: application/json" \
      --post-data "$1" \
      "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/purge_cache"
```

## Database

By default the CNPG operator creates a single-instance PostgreSQL 18 cluster
named `<release>-postgresql`, with the database and role `philomena` and an
ICU `en-US` collation, and generates the role's password into the Secret
`<release>-postgresql-app`. The chart reads `username` and `password` from it
and builds `DATABASE_URL`. To use credentials of your own, point
`postgresql.cluster.initdb.secret.name` at a `kubernetes.io/basic-auth`
Secret whose `username` equals `postgresql.cluster.initdb.owner`.

CNPG's default `max_connections` is 100. The app, the worker and each running
cron job open `POOL_SIZE` connections (16 unless the env Secret says
otherwise), the setup Job `setupJob.poolSize`; raise
`postgresql.cluster.postgresql.parameters.max_connections` along with
`POOL_SIZE` or the replica counts.

Backups are off by default. Continuous WAL archiving and scheduled base
backups are configured through the subchart's `postgresql.backups.*`; see
[Backups](https://github.com/philomena-dev/helm-charts#backups) in the
deployment guide for a working configuration with the Barman Cloud plugin.

### External database

```yaml
postgresql:
  enabled: false
externalDatabase:
  host: postgres.example.com
  port: 5432
  database: philomena
  existingSecret: philomena-db  # "username" and "password" keys
```

No CNPG operator is needed then. Create the database with an ICU `en-US`
locale, as upstream does (`initdb --locale-provider=icu --icu-locale=en-US`,
or `CREATE DATABASE ... LOCALE_PROVIDER icu ICU_LOCALE 'en-US' TEMPLATE
template0`), owned by the role in the Secret. The password ends up in a URL,
so avoid characters that need URL-encoding. `setup-production` creates the
`citext` extension itself, which a non-superuser owner may do on PostgreSQL
13 and newer.

## OpenSearch

Philomena talks to OpenSearch over plain HTTP without authentication, so the
bundled node runs alone with the security plugin disabled, as in upstream's
Docker setup. Nothing but the app pods should be able to reach it;
`networkPolicy.enabled` enforces that where the CNI supports it
([Network policies](#network-policies)).
`opensearch.masterService` names the Service the app connects to and must
stay `<clusterName>-<nodeGroup>` of the subchart; it is not prefixed with the
release name, so two releases in one namespace need different
`opensearch.clusterName` values.

OpenSearch refuses to start unless the node's `vm.max_map_count` is at least
262144. Set it on the nodes, or let the subchart do it with a privileged init
container (`opensearch.sysctlInit.enabled: true`).

Size the heap with `opensearch.opensearchJavaOpts` (`-Xms` equal to `-Xmx`,
about half of the container's memory). The index is not backed up: it is
rebuilt from the database by `Philomena.Release.migrate_search()`.

For an external cluster, set `opensearch.enabled: false` and
`externalOpensearch.url`. If the URL carries credentials, put
`OPENSEARCH_URL` into the env Secret instead and leave the value empty.

## Valkey

Valkey holds the job queue and carries PubSub between the app and the
worker. The app connects without authentication on port 6379. The bundled instance has no volume by default
(`valkey.dataStorage.enabled`), so jobs queued at the moment it restarts are
lost. For an external instance, set `valkey.enabled: false` and
`externalValkey.host`.

## mediaproc

Philomena hands all media processing (analysis, thumbnails, transcoding) to
the media processor over an RPC port; uploads fail while it is down. It is the component that
bursts: video transcoding and large images take whatever CPU and memory its
limits allow, so give it generous limits on a node that has them. To run it
elsewhere, set `mediaproc.enabled: false` and `externalMediaproc.addr`
(`host:port`).

## Web sidecar

Every app pod runs the `philomena-web` image, a Caddy build with the rate
limit and S3 plugins, as a sidecar; the Service, the Ingress and the
HTTPRoute point at it. Caddy

- serves the static assets baked into the image (CSS, JS, fonts, favicon)
  with long cache headers and compression,
- proxies everything else to the app on `localhost:4000`,
- applies a per-client rate limit (`web.rateLimit`), the upload size limit
  (`web.maxBodySize`) and the error and downtime pages,
- works out the client's IP address from `web.clientIpHeaders` when the
  request comes from one of `web.trustedProxies`.

The chart generates the Caddyfile from `web.*`; `web.config` replaces it
entirely. `web.downtime: true` answers every request with the maintenance
page.

The client IP matters: bans, rate limits and moderation tools use it. The
defaults trust every private address and read `CF-Connecting-IP` first, which
suits a site behind Cloudflare and an ingress controller. Narrow
`web.trustedProxies` to the addresses your ingress controller connects from
(usually the pod network), and drop `CF-Connecting-IP` from
`web.clientIpHeaders` when Cloudflare is not in front, since nothing would
stop a visitor from sending that header.

### Uploaded files (the CDN domain)

Browsers load uploaded images, avatars and badges from `CDN_HOST`, with URLs
that have to be mapped onto the objects in the S3 bucket
(`/img/view/2024/1/1/123__tags.png` is `images/2024/1/1/123/full.png`). The
chart can serve that domain from the web sidecar, the way upstream's
production web server does:

```yaml
web:
  cdn:
    enabled: true
    hosts:
      - cdn.philomena.example
ingress:
  hosts:
    - host: philomena.example
    - host: cdn.philomena.example
```

The bucket, endpoint and credentials are read from the app's env Secret
(`S3_BUCKET`, `S3_SCHEME`, `S3_HOST`, `S3_PORT`, `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY`) unless `web.cdn.s3.*` says otherwise. The mapping
assumes the URL and file roots of
[`examples/philomena.env`](https://github.com/philomena-dev/helm-charts/blob/main/examples/philomena.env).

It is off by default, and large sites keep it off: they serve the CDN domain
from a caching proxy or CDN outside the cluster, so that image traffic never
reaches the app pods.

## Installing, upgrading and rolling back

Two Jobs run `setup-production` from the app image, with the app's
environment plus `setupJob.extraEnv` and `POOL_SIZE=<setupJob.poolSize>`:

1. **Preflight** (`setupJob.preflight.enabled`): `setup-production
   --preflight` checks whether the database can be upgraded to this release.
   A failure aborts the upgrade before the database is touched; its log says
   what to do, for example to pass a decision such as `ACCEPT_USER_RENAMES=1`
   through `setupJob.extraEnv`.
2. **Setup**: waits for PostgreSQL and OpenSearch, initializes an empty
   database or migrates an existing one, runs the release migrations and
   creates or migrates the search indexes. The Job is kept until the next
   run; read its log with `kubectl logs job/<release>-setup-production`.

| | Preflight | Setup | Workloads |
| :-- | :-------- | :---- | :-------- |
| `helm install` | not run | `post-install` hook | started with the rest of the release; they restart until the setup Job has finished |
| `helm upgrade` | `pre-upgrade` hook, weight -5 | `pre-upgrade` hook, weight 0 | rolled out after both |
| Argo CD sync | `Sync` hook, wave 1 | `Sync` hook, wave 2 | wave 3 |

Things to know:

- Helm waits for hooks within `--timeout`, which is 5 minutes by default.
  Pass a longer one whenever a release migrates (`helm upgrade --timeout 3h
  ...`). The setup Job itself has no deadline unless
  `setupJob.activeDeadlineSeconds` is set.
- Neither Job retries. A failed migration needs a look; `setup-production`
  can be run again afterwards by repeating the upgrade.
- Building the search indexes runs one batch task per CPU of
  `setupJob.resources.limits.cpu`. On a large site, raise it before the first
  run and before upgrades that rebuild an index: millions of images take
  hours with 2 CPUs and minutes with 16.
- Upstream recommends stopping the app while `setup-production` migrates.
  The Jobs run before the workloads are touched, so a release with release
  migrations takes two upgrades (or syncs): first the running version with
  `replicaCount: 0`, `worker.replicaCount: 0` and `cron.suspend: true`, then
  the new `image.tag` without them, which migrates and brings the workloads
  back.
- `setupJob.enabled: false` skips both Jobs, to bring the services up without
  touching the database (for example to restore a dump first).
- Under Argo CD the Jobs run in every sync, after the database and
  OpenSearch are healthy. The chart carries Argo CD's own hook annotations
  for that, since Argo CD cannot tell an install from an upgrade and would
  otherwise run the `pre-upgrade` hooks before the database exists.
- `helm rollback` and syncing an older revision only revert the workloads.
  Database migrations are never undone.

### Restore point before migrating

With `setupJob.restorePoint.enabled: true`, the setup Job first creates a
named PostgreSQL restore point (`<namePrefix>-<image tag>-<UTC timestamp>`),
switches to a new WAL segment and waits up to
`setupJob.restorePoint.archiveTimeoutSeconds` for the old one to be archived.
The upgrade fails when it is not archived in time, so a broken archive is
caught before the migration runs. Nothing is done while the database is
still uninitialized.

This needs working WAL archiving and the grants in the default
`postgresql.cluster.initdb.postInitApplicationSQL`; for an external
database, grant `EXECUTE` on `pg_create_restore_point(text)` and
`pg_switch_wal()` to the app role. Enable it only after the first base backup
has completed and the archiver has caught up: right after a restore or a big
migration there can be hours of WAL in the queue, and the wait times out.

The restore point's name and LSN are in the setup Job's log. To undo a
migration, bootstrap a new CNPG Cluster from the backups with
`recoveryTarget.targetName` set to it (CNPG recovers into a new Cluster, not
in place), point the release at it, and accept the loss of writes made after
the upgrade.

## Scheduled tasks

`cron.jobs` runs upstream's `run-cron` every five minutes and
`run-cron-daily` once a day, as CronJobs in the app image. `cron.suspend:
true` pauses all of them without removing the CronJobs; a job entry can also
carry its own `suspend`, `timeZone`, `activeDeadlineSeconds` and `resources`.

For one-off commands (a reindex, a release task),
[`scripts/philomena-task.sh`](https://github.com/philomena-dev/helm-charts/blob/main/scripts/philomena-task.sh)
clones the `cron` CronJob into a Job with another command, so `cron.enabled`
has to stay on for it to work.

## Public dump

`publicDump.enabled: true` adds a CronJob (04:00 UTC by default) that
publishes an anonymized dump of the database. Each run:

1. starts a throwaway PostgreSQL as a sidecar of the Job pod on an ephemeral
   volume (`publicDump.scratch.*`), tuned for loading rather than durability;
2. copies the public schema's structure and the data of `publicDump.tables`
   into it with parallel `pg_dump`/`pg_restore`, reading from the bundled
   cluster's read-only service when it has replicas, otherwise from the
   primary (`publicDump.sourceHost` overrides);
3. runs `files/public-dump.sql`, which builds the published tables (hidden
   images, anonymous authorship, non-public forums, deleted and hidden posts
   and every user column but id and name are left out), drops the originals
   and keeps only the result. The URLs it writes come from `IMAGE_URL_ROOT`
   and `BADGE_URL_ROOT` of the app's environment (the Secret or `env`).
   Replace the SQL with `publicDump.existingConfigMap` (key
   `public-dump.sql`);
4. writes `<namePrefix>_<YYYY_MM_DD>.pgdump`, a `latest.json` (file, size,
   sha256, created_at) and an `index.html`, and uploads them with rclone to
   `publicDump.s3.*`, the dump first. Dumps older than
   `publicDump.upload.retention` are then deleted from the bucket.

`index.html` is the download page: the link to the dump with its size and
checksum, how to load a dump, and the layout of the published tables, read
from the dump that was just built. It is a single file, styled with
[PhilomenaCSS](https://github.com/Meow/PhilomenaCSS), and links the dump by
its file name, so it works from wherever the bucket is served.
`publicDump.page.siteName` is the name of the site on it and
`publicDump.page.siteUrl` the address it links to (`APP_ORIGIN` of the app's
environment when empty); `publicDump.page.enabled: false` leaves the page
out.

The S3 credentials come from a Secret with `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY` keys (`publicDump.s3.existingSecret`); use a key
scoped to that bucket, not the app's. Serving the files is left to whatever
fronts the bucket. A dump never changes once it is uploaded and can be
cached for good; `latest.json` and `index.html` are replaced by every run,
so cache them briefly, and serve `index.html` for the root of the domain.
Size the scratch volume at about three times the public tables and keep it
off the database's disk if you can, keep the PostgreSQL image's major
version equal to the database's, and expect the run to compete with the site
for I/O on a single-instance cluster. Sidecar containers need Kubernetes
1.29 or newer.

The scripts, the SQL and the page template in `files/` are copies of the
ones in the philomena-public-dump repository, which the Docker Compose
deployment runs as well; `scripts/sync-public-dump.sh` in the chart
repository updates them.

## Security

- The app, worker, mediaproc, web, setup and cron containers run as
  unprivileged users with all capabilities dropped (the web container keeps
  `NET_BIND_SERVICE`, which its binary needs to be executable), no privilege
  escalation and the runtime's default seccomp profile. They meet the
  `restricted` Pod Security Standard, as do the bundled Valkey and
  PostgreSQL.
- The OpenSearch subchart and the public dump's PostgreSQL sidecar start as
  root. A namespace that holds them can enforce `baseline`, not `restricted`.
- No workload talks to the Kubernetes API; no service account token is
  mounted.
- `networkPolicy.enabled` isolates the bundled services; see below.

### Network policies

`networkPolicy.enabled: true` adds one NetworkPolicy for each of the bundled
PostgreSQL, OpenSearch, Valkey and mediaproc. It needs a CNI that enforces
NetworkPolicies. With them:

- only the pods running the app image (app, worker, setup Jobs, cron jobs)
  reach the services, each on its own port; the public dump reaches
  PostgreSQL. OpenSearch, Valkey and mediaproc do not authenticate their
  clients, so this is what keeps other pods of the cluster out.
  `networkPolicy.extraFrom` lets more peers in, e.g. a monitoring namespace;
- the services reach nothing but their own replicas and the cluster DNS
  (`k8s-app: kube-dns` pods in `kube-system`), mediaproc nothing at all.
  Neither another pod nor an address outside the cluster is reachable from
  them.

PostgreSQL needs two exceptions, which is what `networkPolicy.postgresql` is
for:

```yaml
networkPolicy:
  enabled: true
  postgresql:
    apiServer:
      cidrs:
        - 203.0.113.10/32
```

- **Kubernetes API.** The CloudNativePG instances do not run without it, so
  `apiServer.cidrs` is required: the addresses listed by
  `kubectl get endpointslices -n default kubernetes` (the nodes of the
  control plane on most clusters), and `apiServer.ports` when the API
  listens on neither 6443 nor 443. A policy that misses the API server
  leaves the instance pods unable to start. Cilium does not match cluster
  nodes by address unless `policy-cidr-match-mode` includes `nodes`; where
  that is not an option, set `networkPolicy.postgresql.enabled: false` and
  write a CiliumNetworkPolicy for the database instead.
- **Backups.** The instances upload WAL and backups to the object store
  themselves, and download from it on recovery. With `postgresql.backups`
  enabled the chart refuses to render until
  `networkPolicy.postgresql.extraEgress` has a rule, e.g. port 443 of the
  provider's address range. That is the one way out of the cluster the
  database then has.

The operator is let in from `networkPolicy.postgresql.operatorNamespace`
(`cnpg-system`). The policies do not restrict the app pods themselves, which
talk to S3, SMTP and other sites.

## Values

Only the chart's own values are listed; `values.yaml` documents each of them
in full, and `values.schema.json` rejects misspelled keys.

| Key | Description | Default |
| :-- | :---------- | :------ |
| `image.repository` | App image (app, worker, setup Jobs, cron) | `ghcr.io/philomena-dev/philomena` |
| `image.tag` | Version of all three Philomena images | chart `appVersion` |
| `image.digest` | Digest of the app image; wins over the tag | `""` |
| `image.pullPolicy` | Pull policy, also the default for the other two images | `IfNotPresent` |
| `image.pullSecrets` | Existing image pull Secrets, for every pod | `[]` |
| `registryCredentials.*` | Create a docker-registry Secret and pull with it | disabled |
| `existingSecret` | Secret with the app's environment | `""` |
| `env` | Non-secret environment variables (map) | `{}` |
| `extraEnv` | Extra environment variables (list of `EnvVar`) | `[]` |
| `siteConfig` | Replacement `config/*.json` files (file name → content) | `{}` |
| `purgeCache.script` | Replacement for the image's `purge-cache` script | `""` |
| `extraVolumes` / `extraVolumeMounts` | Extra volumes for the app image containers | `[]` |
| `infisical.*` | [`infisical-secret`](../infisical-secret/) subchart | disabled |
| `replicaCount` | App replicas | `1` |
| `strategy` | Rollout strategy of the app Deployment | `{}` |
| `resources` | App resources | 500m / 1Gi requested, 4 CPU / 4Gi limit |
| `probes.liveness` / `probes.readiness` | HTTP probes of the app (`path` plus any probe field) | `/robots.txt` |
| `nodeSelector` / `tolerations` / `affinity` | Scheduling of the app, worker, Jobs, cron and public dump | none |
| `podAnnotations` / `podLabels` | Extra pod metadata, all workloads | `{}` |
| `podSecurityContext` | Pod security context, all pods but the public dump's | `RuntimeDefault` seccomp |
| `securityContext` | Security context of the app image containers | non-root (1000), no capabilities |
| `automountServiceAccountToken` | Mount a service account token | `false` |
| `web.image.*` | Web image; `tag` and `pullPolicy` default to `image.*` | `ghcr.io/philomena-dev/philomena-web` |
| `web.port` | Port Caddy listens on in the pod | `8080` |
| `web.trustedProxies` | Proxies whose client IP headers are trusted | `[private_ranges]` |
| `web.clientIpHeaders` | Headers the client IP is read from | `[CF-Connecting-IP, X-Forwarded-For]` |
| `web.rateLimit.*` | Per-client request limit: `enabled`, `events`, `window` | 30 requests per 5s |
| `web.maxBodySize` | Largest request body (uploads) | `130MiB` |
| `web.downtime` | Serve the downtime page for every request | `false` |
| `web.cdn.*` | Serve the CDN domain from S3: `enabled`, `hosts`, `s3.{bucket,endpoint,region,usePathStyle,existingSecret}` | disabled |
| `web.config` | Complete Caddyfile replacing the generated one | `""` |
| `web.extraEnv`, `web.probes.*`, `web.securityContext`, `web.resources` | The rest of the web container | see `values.yaml` |
| `service.*` | Service in front of the web sidecar: `type`, `port`, `nodePort`, `annotations`, load balancer options | `ClusterIP`, port 80 |
| `ingress.*` | Ingress: `enabled`, `className`, `annotations`, `hosts`, `tls` | disabled |
| `httpRoute.*` | Gateway API HTTPRoute: `enabled`, `parentRefs`, `hostnames`, `annotations` | disabled |
| `worker.*` | Worker: `enabled`, `replicaCount`, `resources` | enabled, 1 replica |
| `mediaproc.*` | Media processor: `enabled`, `replicaCount`, `image.*`, `service.*`, `probes.*`, `extraEnv`, `securityContext`, `resources`, `nodeSelector`, `tolerations`, `affinity` | enabled, 1 replica |
| `setupJob.enabled` | Run the preflight and setup Jobs | `true` |
| `setupJob.preflight.*` | Preflight Job: `enabled`, `activeDeadlineSeconds` | enabled, 600s |
| `setupJob.restorePoint.*` | Restore point before migrating: `enabled`, `namePrefix`, `archiveTimeoutSeconds` | disabled |
| `setupJob.poolSize`, `setupJob.extraEnv`, `setupJob.activeDeadlineSeconds`, `setupJob.resources` | The rest of the setup Jobs | pool of 3, no deadline, 4 CPU / 4Gi limit |
| `cron.*` | CronJobs: `enabled`, `suspend`, `jobs`, `concurrencyPolicy`, history limits, `activeDeadlineSeconds`, `resources` | `run-cron` every 5 min, `run-cron-daily` at 08:00 UTC |
| `publicDump.*` | Public dump CronJob | disabled |
| `postgresql.*` | CNPG `cluster` subchart | enabled, 1 instance, 20Gi, ICU `en-US` |
| `externalDatabase.*` | External PostgreSQL: `host`, `port`, `database`, `existingSecret` | unset |
| `valkey.*` | Valkey subchart | enabled, no volume |
| `externalValkey.host` | External Valkey | `""` |
| `opensearch.*` | OpenSearch subchart | enabled, single node, 1g heap, 20Gi |
| `externalOpensearch.url` | External OpenSearch | `""` |
| `externalMediaproc.addr` | External mediaproc (`host:port`) | `""` |
| `networkPolicy.enabled` | NetworkPolicies isolating the bundled services | `false` |
| `networkPolicy.extraFrom` | Extra peers allowed into the bundled services | `[]` |
| `networkPolicy.postgresql.*` | PostgreSQL policy: `enabled`, `apiServer.cidrs` (required), `apiServer.ports`, `operatorNamespace`, `extraEgress` | enabled, ports 443 and 6443, `cnpg-system` |
