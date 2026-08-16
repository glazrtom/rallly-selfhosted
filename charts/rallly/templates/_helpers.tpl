{{/*
Expand the name of the chart.
*/}}
{{- define "rallly.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "rallly.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "rallly.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "rallly.labels" -}}
helm.sh/chart: {{ include "rallly.chart" . }}
{{ include "rallly.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "rallly.selectorLabels" -}}
app.kubernetes.io/name: {{ include "rallly.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Selector labels for the app component specifically. Kubernetes label
selectors do subset matching, so a selector built from rallly.selectorLabels
alone (name+instance) also matches the bundled Postgres/Garage pods, which
carry those same two labels plus their own component label. Anything that
needs to target ONLY the app pods (the app Service, Deployment selector,
PDB, NetworkPolicy) must use this instead.
*/}}
{{- define "rallly.appSelectorLabels" -}}
{{ include "rallly.selectorLabels" . }}
app.kubernetes.io/component: app
{{- end }}

{{- define "rallly.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "rallly.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "rallly.secretName" -}}
{{ include "rallly.fullname" . }}
{{- end }}

{{- define "rallly.configMapName" -}}
{{ include "rallly.fullname" . }}
{{- end }}

{{- define "rallly.postgresql.fullname" -}}
{{ include "rallly.fullname" . }}-postgresql
{{- end }}

{{- define "rallly.postgresql.secretName" -}}
{{ include "rallly.postgresql.fullname" . }}
{{- end }}

{{- define "rallly.garage.fullname" -}}
{{ include "rallly.fullname" . }}-garage
{{- end }}

{{- define "rallly.garage.secretName" -}}
{{ include "rallly.garage.fullname" . }}
{{- end }}

{{- define "rallly.garage.configMapName" -}}
{{ include "rallly.garage.fullname" . }}
{{- end }}

{{/*
Resolve an image reference from a {registry, repository, tag} map, honouring
global.imageRegistry as an override.
*/}}
{{- define "rallly.image" -}}
{{- $registry := .image.registry -}}
{{- if .global.imageRegistry -}}
{{- $registry = .global.imageRegistry -}}
{{- end -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" $registry .image.repository .image.tag -}}
{{- else -}}
{{- printf "%s:%s" .image.repository .image.tag -}}
{{- end -}}
{{- end }}

{{/*
Resolve the app image, defaulting the tag to the chart's appVersion.
*/}}
{{- define "rallly.appImage" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- include "rallly.image" (dict "image" (dict "registry" .Values.image.registry "repository" .Values.image.repository "tag" $tag) "global" .Values.global) -}}
{{- end }}

{{/*
Merged imagePullSecrets: global + image-specific.
*/}}
{{- define "rallly.imagePullSecrets" -}}
{{- $secrets := concat (.Values.global.imagePullSecrets | default list) (.Values.image.pullSecrets | default list) -}}
{{- if $secrets }}
imagePullSecrets:
{{- range $secrets }}
  - name: {{ if kindIs "string" . }}{{ . }}{{ else }}{{ .name }}{{ end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Resolve a StorageClass name for a volume-level override, falling back to
global.storageClass, then omitting the field entirely (cluster default).
A literal "-" renders as storageClassName: "" (disables dynamic provisioning).
*/}}
{{- define "rallly.storageClass" -}}
{{- $local := .local -}}
{{- $global := .global.storageClass -}}
{{- if $local }}
{{- if eq $local "-" }}
storageClassName: ""
{{- else }}
storageClassName: {{ $local | quote }}
{{- end }}
{{- else if $global }}
{{- if eq $global "-" }}
storageClassName: ""
{{- else }}
storageClassName: {{ $global | quote }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Look up an existing value at a JSON-pointer-ish path within a Secret's data,
base64-decoded. Used to keep generated secrets stable across `helm upgrade`.
Usage: include "rallly.existingSecretValue" (dict "context" $ "name" $secretName "key" "SOME_KEY")
*/}}
{{- define "rallly.existingSecretValue" -}}
{{- $existing := lookup "v1" "Secret" .context.Release.Namespace .name -}}
{{- if $existing -}}
{{- index $existing.data .key | default "" | b64dec -}}
{{- end -}}
{{- end }}

{{/*
Resolve a generated secret value: explicit value > existing value in the live
Secret > a freshly generated random string. Keeps values stable across
`helm upgrade` without requiring the user to set anything.
Usage: include "rallly.generateSecret" (dict "context" $ "value" .Values.foo "secretName" $secretName "key" "FOO" "length" 32)
*/}}
{{- define "rallly.generateSecret" -}}
{{- $existing := include "rallly.existingSecretValue" (dict "context" .context "name" .secretName "key" .key) -}}
{{- if .value -}}
{{- .value -}}
{{- else if $existing -}}
{{- $existing -}}
{{- else -}}
{{- randAlphaNum (.length | default 32) -}}
{{- end -}}
{{- end }}

{{/*
Same as rallly.generateSecret, but the freshly-generated branch produces
lowercase hex instead of alphanumeric. Garage's rpc_secret specifically
requires N bytes of hex (2*N hex characters), not arbitrary alphanumerics.
Usage: include "rallly.generateHexSecret" (dict "context" $ "value" ... "secretName" ... "key" ... "length" 64)
*/}}
{{- define "rallly.generateHexSecret" -}}
{{- $existing := include "rallly.existingSecretValue" (dict "context" .context "name" .secretName "key" .key) -}}
{{- if .value -}}
{{- .value -}}
{{- else if $existing -}}
{{- $existing -}}
{{- else -}}
{{- randAlphaNum 40 | sha256sum | trunc (.length | default 64) -}}
{{- end -}}
{{- end }}

