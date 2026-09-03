{{/*
The CoreDNS delivery this cluster uses. Resolves "auto" to a concrete mode, so the two templates
that render the mechanisms agree on one answer.

"auto" asks the cluster whether it serves the HelmChart kind. RKE2 does, because its helm-controller
manages that resource and also owns the rke2-coredns release.

The test names HelmChart and not HelmChartConfig on purpose. A cluster can carry the
HelmChartConfig CRD alone as a compatibility shim, so that a chart which sends the object applies
without an error. SPUR installs k0s this way. The shim has no controller behind it, so a
HelmChartConfig lands and nothing reads it. Only the HelmChart kind shows a real helm-controller.
*/}}
{{- define "envoy-gateway-config.corednsMode" -}}
{{- $mode := .Values.coredns.mode | default "auto" -}}
{{- if eq $mode "auto" -}}
{{- if .Capabilities.APIVersions.Has "helm.cattle.io/v1/HelmChart" -}}
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
