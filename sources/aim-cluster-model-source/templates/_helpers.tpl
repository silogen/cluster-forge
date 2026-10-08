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
Return "true" when this image passes modelFilters.
excludedOrigins drops a matching origin. maxParameterBillions drops a model
whose total parameter count is greater than that number. 0 disables the size
check. An empty origin list drops nothing.
*/}}
{{- define "aim.allowModel" -}}
{{- $root := index . 0 -}}
{{- $image := index . 1 -}}
{{- $repo := regexReplaceAll ":.*" $image "" -}}
{{- $catalog := $root.Files.Get "model-attributes.yaml" | fromYaml -}}
{{- $entry := index $catalog.models $repo -}}
{{- if not $entry -}}
{{- fail (printf "AIM model %s has no entry in model-attributes.yaml" $repo) -}}
{{- end -}}
{{- $filters := $root.Values.modelFilters | default dict -}}
{{- $excluded := $filters.excludedOrigins | default (list) -}}
{{- if kindIs "string" $excluded -}}
{{- $parsed := list -}}
{{- range splitList "," $excluded -}}
{{- $token := trim . -}}
{{- if $token -}}{{- $parsed = append $parsed $token -}}{{- end -}}
{{- end -}}
{{- $excluded = $parsed -}}
{{- end -}}
{{- $max := int ($filters.maxParameterBillions | default 0) -}}
{{- $size := int $entry.parameterBillions -}}
{{- $originExcluded := has (toString $entry.origin) $excluded -}}
{{- $sizeExcluded := and (gt $max 0) (gt $size $max) -}}
{{- if or $originExcluded $sizeExcluded -}}false{{- else -}}true{{- end -}}
{{- end -}}

{{/*
JSON array of images that pass modelFilters. Order follows the input list.
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
because spec.filters must contain at least one item.
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
