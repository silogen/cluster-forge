{{/*
Normalize .Values.hardwareFamilies into a clean list of family tokens.
Accepts a native list (the primary path, injected by cluster-bloom) or a
comma-separated string. Trims whitespace and drops empty tokens. Empty input
yields an empty list, which triggers the legacy branch.
*/}}
{{- define "aim.hardwareFamilies" -}}
{{- $raw := .Values.hardwareFamilies -}}
{{- $out := list -}}
{{- if kindIs "string" $raw -}}
  {{- range (splitList "," $raw) -}}
    {{- $t := trim . -}}
    {{- if $t -}}{{- $out = append $out $t -}}{{- end -}}
  {{- end -}}
{{- else if kindIs "slice" $raw -}}
  {{- range $raw -}}
    {{- $t := trim (toString .) -}}
    {{- if $t -}}{{- $out = append $out $t -}}{{- end -}}
  {{- end -}}
{{- end -}}
{{- $out | toJson -}}
{{- end -}}
