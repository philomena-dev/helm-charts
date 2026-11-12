{{- define "infisical-secret.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Default name for an entry: "<release>-<key>". Used for both the
InfisicalSecret and (unless secretName is set) the managed Secret. Parent
charts mirror this to find the Secret; keep them in sync.
*/}}
{{- define "infisical-secret.defaultName" -}}
{{- printf "%s-%s" .release .key | trunc 63 | trimSuffix "-" -}}
{{- end -}}
