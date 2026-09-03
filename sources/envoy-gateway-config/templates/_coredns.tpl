{{/*
The CoreDNS delivery this cluster uses. Resolves "auto" to a concrete mode, so the two templates
that render the mechanisms agree on one answer.

"auto" asks the cluster whether it serves helm.cattle.io/v1. RKE2 does, because its helm-controller
is what owns the rke2-coredns release. Nothing else does.
*/}}
{{- define "envoy-gateway-config.corednsMode" -}}
{{- $mode := .Values.coredns.mode | default "auto" -}}
{{- if eq $mode "auto" -}}
{{- if .Capabilities.APIVersions.Has "helm.cattle.io/v1" -}}
helmChartConfig
{{- else -}}
patchJob
{{- end -}}
{{- else -}}
{{- $mode -}}
{{- end -}}
{{- end -}}

{{/*
The one CoreDNS rewrite rule, as it appears in a Corefile. Both mechanisms deliver this same line,
so it is written once.
*/}}
{{- define "envoy-gateway-config.corednsRewrite" -}}
rewrite continue name regex .*\.{{ .Values.domain }} https.envoy-gateway-system.svc.cluster.local answer auto
{{- end -}}
