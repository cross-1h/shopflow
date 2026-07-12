{{/* Common labels applied to every object */}}
{{- define "shopflow.labels" -}}
app.kubernetes.io/part-of: shopflow
app.kubernetes.io/managed-by: Helm
{{- end -}}

{{/* Build a full image reference for a service repo */}}
{{- define "shopflow.image" -}}
{{- printf "%s/%s:%v" .registry .repo .tag -}}
{{- end -}}
