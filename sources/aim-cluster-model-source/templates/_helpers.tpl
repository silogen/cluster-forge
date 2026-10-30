{{/*
Normalize .Values.hardwareFamilies into a clean list of family tokens.
Accepts a native list (the primary path, injected by cluster-bloom) or a
comma-separated string. Trims whitespace and drops empty tokens. Empty input
yields an empty list, which triggers the unfiltered catalog (templates/unfiltered.yaml).
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

{{/*
Normalize a provider list. Accepts a native list or a comma-separated string.
*/}}
{{- define "aim.providerList" -}}
{{- $raw := . -}}
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

{{/*
Return "true" when any pattern in the list matches the image reference.
Each pattern is a regular expression. An empty list matches nothing.
*/}}
{{- define "aim.imageMatches" -}}
{{- $image := index . 0 -}}
{{- $patterns := index . 1 -}}
{{- $hit := false -}}
{{- range $patterns -}}
{{- if regexMatch . $image -}}
{{- $hit = true -}}
{{- end -}}
{{- end -}}
{{- if $hit -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{/*
Return "true" when the image reference matches includeProviders and does not
match excludeProviders. excludeProviders takes priority. Patterns are regular
expressions, so "google" matches aim-epyc-google-gemma-4-e4b-it.
*/}}
{{- define "aim.allowModel" -}}
{{- $root := index . 0 -}}
{{- $image := index . 1 -}}
{{- $included := include "aim.providerList" $root.Values.includeProviders | fromJsonArray -}}
{{- $excluded := include "aim.providerList" $root.Values.excludeProviders | fromJsonArray -}}
{{- $blocked := include "aim.imageMatches" (list $image $excluded) -}}
{{- $allowed := include "aim.imageMatches" (list $image $included) -}}
{{- if eq $blocked "true" -}}false{{- else if eq $allowed "true" -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{/*
JSON array of images that match the provider patterns. Order follows the input list.
*/}}
{{- define "aim.selectedImages" -}}
{{- $root := index . 0 -}}
{{- $images := index . 1 -}}
{{- $kept := list -}}
{{- range $image := $images -}}
{{- if eq (include "aim.allowModel" (list $root $image)) "true" -}}
{{- $kept = append $kept $image -}}
{{- end -}}
{{- end -}}
{{- $kept | toJson -}}
{{- end -}}

{{/*
One AIMClusterModelSource. Emits nothing when every image is filtered out,
because spec.filters must contain at least one item. Base sources do not use
this define.
*/}}
{{- define "aim.modelSource" -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
{{- $images := index . 2 -}}
{{- $selected := include "aim.selectedImages" (list $root $images) | fromJsonArray -}}
{{- if $selected }}
---
apiVersion: aim.eai.amd.com/v1alpha1
kind: AIMClusterModelSource
metadata:
  name: {{ $name }}
spec:
  filters:
{{- range $image := $selected }}
    - image: {{ $image }}
{{- end }}
  maxModels: 100
  registry: docker.io
  syncInterval: 1h
{{- end }}
{{- end -}}
