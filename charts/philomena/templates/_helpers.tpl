{{/*
Expand the name of the chart.
*/}}
{{- define "philomena.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "philomena.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Create chart name and version as a unique label.
*/}}
{{- define "philomena.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "philomena.labels" -}}
helm.sh/chart: {{ include "philomena.chart" . }}
{{ include "philomena.selectorLabels" . }}
app.kubernetes.io/version: {{ include "philomena.tag" . | trunc 63 | trimSuffix "-" | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "philomena.selectorLabels" -}}
app.kubernetes.io/name: {{ include "philomena.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Version of the Philomena images: image.tag, or the chart's appVersion.
*/}}
{{- define "philomena.tag" -}}
{{- .Values.image.tag | default .Chart.AppVersion | toString -}}
{{- end -}}

{{/*
Reference of one of the Philomena images. Its tag falls back to image.tag
(philomena.tag), so one value sets the version of all of them; a digest
takes precedence over any tag.
Usage: include "philomena.imageRef" (dict "ctx" . "image" .Values.web.image)
*/}}
{{- define "philomena.imageRef" -}}
{{- if .image.digest -}}
{{- printf "%s@%s" .image.repository .image.digest -}}
{{- else -}}
{{- printf "%s:%s" .image.repository (.image.tag | default (include "philomena.tag" .ctx) | toString) -}}
{{- end -}}
{{- end -}}

{{- define "philomena.image" -}}
{{- include "philomena.imageRef" (dict "ctx" . "image" .Values.image) -}}
{{- end -}}

{{- define "philomena.webImage" -}}
{{- include "philomena.imageRef" (dict "ctx" . "image" .Values.web.image) -}}
{{- end -}}

{{- define "philomena.mediaprocImage" -}}
{{- include "philomena.imageRef" (dict "ctx" . "image" .Values.mediaproc.image) -}}
{{- end -}}

{{/*
imagePullSecrets block: the chart-created registry Secret plus
image.pullSecrets; empty when there are none.
*/}}
{{- define "philomena.imagePullSecrets" -}}
{{- if or .Values.registryCredentials.create .Values.image.pullSecrets -}}
imagePullSecrets:
  {{- if .Values.registryCredentials.create }}
  - name: {{ .Values.registryCredentials.secretName }}
  {{- end }}
  {{- range .Values.image.pullSecrets }}
  - name: {{ . }}
  {{- end }}
{{- end -}}
{{- end -}}

{{/*
Pod-level fields shared by the pods that run the app image (app, worker,
setup Jobs, cron jobs).
*/}}
{{- define "philomena.appPodSpec" -}}
automountServiceAccountToken: {{ .Values.automountServiceAccountToken }}
{{- with .Values.podSecurityContext }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with include "philomena.imagePullSecrets" . }}
{{ . }}
{{- end }}
{{- end -}}

{{/*
Volume mounts of the app, worker and cron containers: the site
configuration files and the purge-cache script over the ones in the image,
then extraVolumeMounts. The hook Jobs only get extraVolumeMounts (see
philomena.siteConfigScript).
*/}}
{{- define "philomena.appVolumeMounts" -}}
{{- range $file, $_ := .Values.siteConfig }}
- name: site-config
  mountPath: /srv/philomena/config/{{ $file }}
  subPath: {{ $file }}
  readOnly: true
{{- end }}
{{- if .Values.purgeCache.script }}
- name: purge-cache
  mountPath: /usr/local/bin/purge-cache
  subPath: purge-cache
  readOnly: true
{{- end }}
{{- with .Values.extraVolumeMounts }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Volumes behind philomena.appVolumeMounts.
*/}}
{{- define "philomena.appVolumes" -}}
{{- if .Values.siteConfig }}
- name: site-config
  configMap:
    name: {{ include "philomena.fullname" . }}-site-config
{{- end }}
{{- if .Values.purgeCache.script }}
- name: purge-cache
  configMap:
    name: {{ include "philomena.fullname" . }}-purge-cache
    defaultMode: 0555
{{- end }}
{{- with .Values.extraVolumes }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Pod annotations that restart the long-running app image pods when the
mounted configuration changes.
*/}}
{{- define "philomena.appChecksums" -}}
{{- if .Values.siteConfig }}
checksum/site-config: {{ toJson .Values.siteConfig | sha256sum }}
{{- end }}
{{- if .Values.purgeCache.script }}
checksum/purge-cache: {{ .Values.purgeCache.script | sha256sum }}
{{- end }}
{{- end -}}

{{/*
Fields of a probe taken from its values block as they are; "enabled" and
"path" are the chart's own keys.
*/}}
{{- define "philomena.probeSettings" -}}
{{- with omit . "enabled" "path" -}}
{{- toYaml . -}}
{{- end -}}
{{- end -}}

{{/*
Caddyfile for the web sidecar: web.config verbatim when set, otherwise
upstream's docker/production/web/Caddyfile adapted to the pod (static assets
from the image's /var/www, everything else proxied to the app on
localhost). The CDN domain is only served with web.cdn.enabled; it is
otherwise left to whatever fronts the cluster.
*/}}
{{- define "philomena.caddyfile" -}}
{{- if .Values.web.config -}}
{{- .Values.web.config -}}
{{- else -}}
{{- $w := .Values.web -}}
{
	admin off
	persist_config off
	auto_https off
	{{- if $w.cdn.enabled }}

	filesystem philomena s3 {
		bucket {$S3_BUCKET}
		endpoint {$S3_ENDPOINT}
		region {{ $w.cdn.s3.region }}
		{{- if $w.cdn.s3.usePathStyle }}
		use_path_style
		{{- end }}
	}
	{{- end }}

	servers {
		trusted_proxies static {{ $w.trustedProxies | join " " }}
		client_ip_headers {{ $w.clientIpHeaders | join " " }}
	}
}

(cors) {
	@get_and_options method GET OPTIONS
	@only_options method OPTIONS

	header @get_and_options {
		Access-Control-Allow-Origin "*"
		Access-Control-Allow-Methods "GET, OPTIONS"
		Access-Control-Allow-Headers "DNT,Keep-Alive,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type"
	}

	header @only_options {
		Access-Control-Max-Age 1728000
		Content-Type 'text/plain charset=UTF-8'
		Content-Length 0
	}
}
{{- if $w.cdn.enabled }}

(s3path) {
	handle {args[0]} {
		# Images are drawn into cross-origin SVG/canvas contexts (e.g. the
		# duplicate report diff view), which requires CORS headers.
		import cors
		rewrite {args[0]} {args[1]}
		file_server {
			fs philomena
		}
	}
}

(filepath) {
	handle {args[0]} {
		file_server {
			root /var/www
		}

		header Cache-Control "public, max-age=2147483647"
	}
}
{{- end }}

:{{ $w.port | int }} {
	handle_errors 503 {
		rewrite * /downtime.html
		root * /var/www
		file_server
	}

	handle_errors 500 502 504 429 {
		log_skip
		rewrite * /error_50x.html
		root * /var/www
		file_server
	}
	{{- if $w.rateLimit.enabled }}

	rate_limit {
		zone dynamic {
			key {client_ip}
			events {{ $w.rateLimit.events | int }}
			window {{ $w.rateLimit.window }}
		}

		log_key
	}
	{{- end }}
	{{- if $w.downtime }}

	error 503
	{{- else }}

	@json path_regexp /.+\.json$
	@static path_regexp ^/.+\.(ico|js|css|eot|woff|svg|ttf|otf|png|jpg|swf|gif|woff2|mp3)$

	# Asset hits are not worth logging
	log_skip @static

	handle @static {
		encode zstd gzip
		# Only successful responses may be cached: a 404 with this header
		# would stay cached upstream for as long as it says.
		header {
			match status 2xx
			Cache-Control "public, max-age=2147483647"
		}
		file_server {
			root /var/www
		}
	}

	handle @json {
		log_skip
		respond 400
	}

	header Strict-Transport-Security "max-age=31556925"

	request_body {
		max_size {{ $w.maxBodySize }}
	}

	route {
		# Serve files from the image first, then hand over to the app.
		file_server {
			root /var/www
			pass_thru
		}

		import cors

		reverse_proxy 127.0.0.1:4000 {
			header_up X-Real-Ip {client_ip}
			header_up X-Forwarded-For {client_ip}
			header_up X-Forwarded-Ssl on

			header_down X-Frame-Options SAMEORIGIN
		}
	}
	{{- end }}

	log {
		output stdout
		format filter {
			request>headers delete
			request>remote_port delete
			resp_headers delete
			wrap json
		}
		level INFO
	}

	log_append user_agent {http.request.header.User-Agent}
}
{{- if $w.cdn.enabled }}
{{- $port := $w.port | int }}

{{ range $i, $host := required "web.cdn.hosts is required when web.cdn.enabled is true" $w.cdn.hosts }}{{ if $i }}, {{ end }}http://{{ $host }}:{{ $port }}{{ end }} {
	# Handle images and static assets
	@allimages path /img/* /avatars/* /spns/* /badge-img/* /tag-img/*
	@imgdownload path_regexp ^/img/download/(.+)/([0-9]+).*\.([A-Za-z0-9]+)$
	@imgview path_regexp ^/img/view/(.+)/([0-9]+).*\.([A-Za-z0-9]+)$
	@img path_regexp ^/img/(.+)$
	@spns path_regexp ^/spns/(.+)$
	@avatars path_regexp ^/avatars/(.+)$
	@badges path_regexp ^/badges/(.+)$
	@tags path_regexp ^/tags/(.+)$
	@html path_regexp ^/(.+\.html)$
	@static path_regexp ^/(.+\.html|challenge\.css|favicon\.svg)$

	import s3path @imgdownload /images/{re.imgdownload.1}/{re.imgdownload.2}/full.{re.imgdownload.3}
	import s3path @imgview /images/{re.imgview.1}/{re.imgview.2}/full.{re.imgview.3}
	import s3path @img /images/{re.img.1}
	import s3path @avatars /avatars/{re.avatars.1}
	import s3path @spns /adverts/{re.spns.1}
	import s3path @badges /badges/{re.badges.1}
	import s3path @tags /tags/{re.tags.1}

	import filepath @html

	# Files in the bucket may carry a wrong content type (e.g.
	# "application/octet-stream"), so it is set from the file extension.
	map {path} {custom_content_type} {
		~.*\.png$ "image/png"
		~.*\.jpe?g$ "image/jpeg"
		~.*\.gif$ "image/gif"
		~.*\.svg$ "image/svg+xml"
		~.*\.mp4$ "video/mp4"
		~.*\.webm$ "video/webm"
		default "text/html"
	}

	header @allimages {
		Content-Type {custom_content_type}
	}

	# The download path should download the image, not show it.
	header @imgdownload {
		Content-Disposition "attachment"
	}

	handle @static {
		import cors
		encode zstd gzip
		header Cache-Control "public, max-age=2147483647"
		file_server {
			root /var/www
		}
	}

	handle {
		import cors
		respond 404
	}
}
{{- end }}
{{- end -}}
{{- end -}}

{{/*
Environment of the web sidecar: the S3 settings Caddy's "philomena"
filesystem reads when web.cdn is enabled, then web.extraEnv. Values left
empty come from the app's env Secret.
*/}}
{{- define "philomena.webEnv" -}}
{{- if and .Values.web.cdn.enabled (not .Values.web.config) -}}
{{- $s3 := .Values.web.cdn.s3 -}}
{{- $envSecret := include "philomena.envSecretName" . -}}
{{- $credentials := $s3.existingSecret | default $envSecret | required "web.cdn needs S3 credentials: set web.cdn.s3.existingSecret, existingSecret or enable infisical" -}}
{{- $fromEnvSecret := "web.cdn.s3.%s is required when the app has no env Secret (existingSecret or infisical) to read it from" -}}
- name: AWS_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ $credentials }}
      key: AWS_ACCESS_KEY_ID
- name: AWS_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $credentials }}
      key: AWS_SECRET_ACCESS_KEY
- name: S3_BUCKET
  {{- if $s3.bucket }}
  value: {{ $s3.bucket | quote }}
  {{- else }}
  valueFrom:
    secretKeyRef:
      name: {{ required (printf $fromEnvSecret "bucket") $envSecret }}
      key: S3_BUCKET
  {{- end }}
{{- if $s3.endpoint }}
- name: S3_ENDPOINT
  value: {{ $s3.endpoint | quote }}
{{- else }}
{{- range list "S3_SCHEME" "S3_HOST" "S3_PORT" }}
- name: {{ . }}
  valueFrom:
    secretKeyRef:
      name: {{ required (printf $fromEnvSecret "endpoint") $envSecret }}
      key: {{ . }}
{{- end }}
- name: S3_ENDPOINT
  value: "$(S3_SCHEME)://$(S3_HOST):$(S3_PORT)"
{{- end }}
{{- end }}
{{- with .Values.web.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Name of the CNPG Cluster created by the "cluster" subchart (aliased to
"postgresql"); mirrors the subchart's fullname logic.
*/}}
{{- define "philomena.postgresql.fullname" -}}
{{- $name := .Values.postgresql.nameOverride | default "postgresql" -}}
{{- if .Values.postgresql.fullnameOverride -}}
{{- .Values.postgresql.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/* Valkey service name; mirrors the valkey subchart's fullname logic. */}}
{{- define "philomena.valkey.fullname" -}}
{{- $name := .Values.valkey.nameOverride | default "valkey" -}}
{{- if .Values.valkey.fullnameOverride -}}
{{- .Values.valkey.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Database connection as a dict (host, port, database, secret) for the bundled
CNPG cluster or externalDatabase; empty when neither is configured. The
secret holds "username" and "password": the initdb secret if one is set,
otherwise the CNPG-generated "<cluster>-app".
*/}}
{{- define "philomena.database" -}}
{{- if .Values.postgresql.enabled -}}
{{- $cluster := include "philomena.postgresql.fullname" . -}}
{{- dict "host" (printf "%s-rw" $cluster) "port" 5432 "database" .Values.postgresql.cluster.initdb.database "secret" (dig "cluster" "initdb" "secret" "name" "" .Values.postgresql | default (printf "%s-app" $cluster)) | toJson -}}
{{- else if .Values.externalDatabase.host -}}
{{- with .Values.externalDatabase -}}
{{- dict "host" .host "port" (.port | default 5432 | int) "database" .database "secret" (required "externalDatabase.existingSecret is required when externalDatabase.host is set" .existingSecret) | toJson -}}
{{- end -}}
{{- else -}}
{{- dict | toJson -}}
{{- end -}}
{{- end -}}

{{/*
Endpoint environment for the bundled or external services, injected into the
app, worker, setup Jobs and cron jobs. Explicit env entries take precedence
over the same variables from the app Secret (envFrom). The PG* variables are
used by setup-production (pg_isready/psql); the app uses DATABASE_URL.
*/}}
{{- define "philomena.servicesEnv" -}}
{{- $db := include "philomena.database" . | fromJson -}}
{{- with $db }}
- name: PGHOST
  value: {{ .host | quote }}
- name: PGPORT
  value: {{ .port | int | quote }}
- name: PGDATABASE
  value: {{ .database | quote }}
- name: PGUSER
  valueFrom:
    secretKeyRef:
      name: {{ .secret }}
      key: username
- name: PGPASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .secret }}
      key: password
- name: DATABASE_URL
  value: {{ printf "ecto://$(PGUSER):$(PGPASSWORD)@%s:%v/%s" .host (.port | int) .database | quote }}
{{- end }}
{{- if .Values.valkey.enabled }}
- name: REDIS_HOST
  value: {{ include "philomena.valkey.fullname" . | quote }}
{{- else if .Values.externalValkey.host }}
- name: REDIS_HOST
  value: {{ .Values.externalValkey.host | quote }}
{{- end }}
{{- if .Values.opensearch.enabled }}
- name: OPENSEARCH_URL
  value: {{ printf "http://%s:9200" (required "opensearch.masterService is required" .Values.opensearch.masterService) | quote }}
{{- else if .Values.externalOpensearch.url }}
- name: OPENSEARCH_URL
  value: {{ .Values.externalOpensearch.url | quote }}
{{- end }}
{{- if .Values.mediaproc.enabled }}
- name: MEDIAPROC_ADDR
  value: {{ printf "%s-mediaproc:%v" (include "philomena.fullname" .) (.Values.mediaproc.service.port | int) | quote }}
{{- else if .Values.externalMediaproc.addr }}
- name: MEDIAPROC_ADDR
  value: {{ .Values.externalMediaproc.addr | quote }}
{{- end }}
{{- end -}}

{{/*
Full env list for containers running the app image: PORT (the release
configuration reads it in every role, not only where the endpoint is
served), the service endpoints, then the env map and extraEnv.
*/}}
{{- define "philomena.appEnv" -}}
{{- $parts := list "- name: PORT\n  value: \"4000\"" (include "philomena.servicesEnv" . | trim) -}}
{{- range $name, $value := .Values.env -}}
{{- if not (kindIs "invalid" $value) -}}
{{- $parts = append $parts (printf "- name: %s\n  value: %s" $name ($value | toString | quote)) -}}
{{- end -}}
{{- end -}}
{{- with .Values.extraEnv }}{{ $parts = append $parts (toYaml . | trim) }}{{ end -}}
{{- $parts | compact | join "\n" -}}
{{- end -}}

{{/*
Env list for the setup-production containers (preflight and setup Jobs):
the app env, the setup pool size and setupJob.extraEnv.
*/}}
{{- define "philomena.setupEnv" -}}
{{- $parts := list (include "philomena.appEnv" . | trim) -}}
{{- with .Values.setupJob.poolSize }}{{ $parts = append $parts (printf "- name: POOL_SIZE\n  value: %s" (. | toString | quote)) }}{{ end -}}
{{- with .Values.setupJob.extraEnv }}{{ $parts = append $parts (toYaml . | trim) }}{{ end -}}
{{- $parts | compact | join "\n" -}}
{{- end -}}

{{/*
Shell lines that write the siteConfig files over the ones in the image. The
hook Jobs use this instead of mounting the ConfigMap: Helm runs pre-upgrade
hooks before it creates or updates the release's ConfigMaps, so a mount
would be missing or stale there.
*/}}
{{- define "philomena.siteConfigScript" -}}
{{- range $file, $content := .Values.siteConfig }}
echo {{ $content | b64enc | quote }} | base64 -d > {{ printf "/srv/philomena/config/%s" $file | quote }}
{{- end }}
{{- end -}}

{{/*
Shell script run by the preflight Job.
*/}}
{{- define "philomena.preflightScript" -}}
set -eu
{{- include "philomena.siteConfigScript" . }}
exec /usr/local/bin/setup-production --preflight
{{- end -}}

{{/*
Shell script run by the setup Job: optionally creates a PostgreSQL restore
point and waits for its WAL segment to be archived, then runs
setup-production. The restore point is skipped while the database is still
uninitialized (nothing to go back to). Uses the PG* variables and psql from
the app image.
*/}}
{{- define "philomena.setupScript" -}}
{{- $rp := .Values.setupJob.restorePoint -}}
set -eu
{{- include "philomena.siteConfigScript" . }}
{{- if $rp.enabled }}
sql() {
  psql -X -q -tA -v ON_ERROR_STOP=1 "$@"
}

echo "Waiting for database to start..."
until pg_isready -q; do
  sleep 2
done

if [ "$(sql -c "SELECT to_regclass('public.schema_migrations') IS NOT NULL")" != t ]; then
  echo "Database is not initialized yet, not creating a restore point."
else
  name="{{ $rp.namePrefix }}-{{ include "philomena.tag" . }}-$(date -u +%Y%m%dT%H%M%SZ)"
  lsn=$(sql -c "SELECT pg_create_restore_point('$name')")
  segment=$(sql -c "SELECT pg_walfile_name(pg_switch_wal())")
  echo "Created restore point \"$name\" at $lsn (WAL segment $segment)."
  echo "Waiting for the segment to be archived..."

  waited=0
  until [ "$(sql -c "SELECT last_archived_wal >= '$segment' FROM pg_stat_archiver")" = t ]; do
    if [ "$waited" -ge {{ $rp.archiveTimeoutSeconds | int }} ]; then
      echo "WAL segment $segment was not archived within {{ $rp.archiveTimeoutSeconds | int }}s." >&2
      echo "Is WAL archiving (postgresql.backups) configured and healthy?" >&2
      psql -X -c "SELECT last_archived_wal, last_archived_time, last_failed_wal, last_failed_time FROM pg_stat_archiver" >&2
      exit 1
    fi
    sleep 5
    waited=$((waited + 5))
  done

  echo "Archived. To recover the database to the state before this upgrade,"
  echo "use the recovery target name \"$name\" (or LSN $lsn)."
fi
{{- end }}
exec /usr/local/bin/setup-production
{{- end -}}

{{/*
Secrets loaded via envFrom: the existingSecret value when set, otherwise the
Secret synced by the infisical subchart (name mirrors infisical-secret's
"<release>-<key>" default), otherwise none.
Usage: include "philomena.envFromSecretName" (dict "ctx" . "existing" .Values.existingSecret "key" "env")
*/}}
{{- define "philomena.envFromSecretName" -}}
{{- $infisical := .ctx.Values.infisical -}}
{{- $secrets := dig "secrets" (dict) $infisical -}}
{{- $entry := get $secrets .key | default dict -}}
{{- if .existing -}}
{{- .existing -}}
{{- else if and $infisical.enabled (kindIs "map" (get $secrets .key)) (dig "enabled" true $entry) -}}
{{- dig "secretName" "" $entry | default (printf "%s-%s" .ctx.Release.Name .key | trunc 63 | trimSuffix "-") -}}
{{- end -}}
{{- end -}}

{{- define "philomena.envSecretName" -}}
{{- include "philomena.envFromSecretName" (dict "ctx" . "existing" .Values.existingSecret "key" "env") -}}
{{- end -}}

{{/*
Pod selector labels of a subchart's pods, for the NetworkPolicies. All of the
bundled subcharts label their pods the "helm create" way.
Usage: include "philomena.subchartSelector" (dict "ctx" . "name" "valkey")
*/}}
{{- define "philomena.subchartSelector" -}}
app.kubernetes.io/name: {{ dig "nameOverride" "" (get .ctx.Values .name) | default .name }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
{{- end -}}

{{/*
Database host the public dump reads from: publicDump.sourceHost when set,
the bundled cluster's -ro service when it has replicas, otherwise the host
the app uses.
*/}}
{{- define "philomena.publicDump.sourceHost" -}}
{{- if .Values.publicDump.sourceHost -}}
{{- .Values.publicDump.sourceHost -}}
{{- else if and .Values.postgresql.enabled (gt (.Values.postgresql.cluster.instances | int) 1) -}}
{{- printf "%s-ro" (include "philomena.postgresql.fullname" .) -}}
{{- else -}}
{{- (include "philomena.database" . | fromJson).host -}}
{{- end -}}
{{- end -}}

{{/*
Shell script of the public dump's copy-and-transform container (runs in the
PostgreSQL image, next to the scratch server sidecar on localhost).
*/}}
{{- define "philomena.publicDumpScript" -}}
set -eu

: "${IMAGE_URL_ROOT:?IMAGE_URL_ROOT must be set (app Secret)}"
: "${BADGE_URL_ROOT:?BADGE_URL_ROOT must be set (app Secret)}"

scratch="-h 127.0.0.1 -p 5432 -U $SCRATCH_USER"
src=/scratch/source
out=/scratch/out
file="${NAME_PREFIX}_$(date -u +%Y_%m_%d).pgdump"

echo "Waiting for the scratch PostgreSQL..."
until pg_isready -q $scratch; do
  sleep 2
done

rm -rf "$src" "$out"
mkdir -p "$src" "$out"

echo "Copying the schema from $SOURCE_HOST..."
pg_dump -h "$SOURCE_HOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
  -Fc --section=pre-data --no-owner --no-acl -f "$src/schema.pgdump"
pg_restore $scratch -d "$SCRATCH_DB" --no-owner --no-acl "$src/schema.pgdump"

# Unlogged tables load faster, and nothing here has to survive a crash.
psql $scratch -d "$SCRATCH_DB" -X -q -tA -c "SELECT format('ALTER TABLE public.%I SET UNLOGGED;', table_name)
  FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'" |
  psql $scratch -d "$SCRATCH_DB" -X -q -v ON_ERROR_STOP=1

tables=""
for t in $TABLES; do
  tables="$tables -t public.$t"
done

echo "Copying the data of $(echo $TABLES | wc -w) tables..."
pg_dump -h "$SOURCE_HOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
  -Fd -j "$PARALLEL_JOBS" --section=data --no-owner --no-acl $tables -f "$src/data"
pg_restore $scratch -d "$SCRATCH_DB" -j "$PARALLEL_JOBS" --no-owner --no-acl "$src/data"
rm -rf "$src"

echo "Building the public tables..."
PGOPTIONS='--client-min-messages=warning' psql $scratch -d "$SCRATCH_DB" -X -q -v ON_ERROR_STOP=1 \
  -v image_url_root="$IMAGE_URL_ROOT" -v badge_url_root="$BADGE_URL_ROOT" -v work_mem="$WORK_MEM" \
  -f /config/public-dump.sql

echo "Writing $file..."
pg_dump $scratch -d "$SCRATCH_DB" -Fc --no-owner --no-acl -f "$out/$file"

size=$(stat -c %s "$out/$file")
sha=$(sha256sum "$out/$file" | cut -c1-64)
printf '{"file":"%s","size":%s,"sha256":"%s","created_at":"%s"}\n' \
  "$file" "$size" "$sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$out/latest.json"
echo "Done: $file ($size bytes, sha256 $sha)"
{{- end -}}

{{/*
Shell script of the public dump's upload container (rclone image).
*/}}
{{- define "philomena.publicDumpUploadScript" -}}
set -eu

dest="dest:$S3_BUCKET${S3_PATH:+/$S3_PATH}"

echo "Uploading to $dest..."
rclone copy -v /scratch/out "$dest"
{{- if .Values.publicDump.upload.retention }}

echo "Deleting dumps older than {{ .Values.publicDump.upload.retention }}..."
rclone delete -v --min-age {{ .Values.publicDump.upload.retention | quote }} --include '*.pgdump' "$dest"
{{- end }}
echo "Done."
{{- end -}}
