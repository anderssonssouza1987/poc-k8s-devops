{{- define "poc-k8s-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "poc-k8s-app.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "poc-k8s-app.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "poc-k8s-app.labels" -}}
app.kubernetes.io/name: {{ include "poc-k8s-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "poc-k8s-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "poc-k8s-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
