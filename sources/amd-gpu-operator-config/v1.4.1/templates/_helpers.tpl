{{/*
Resolve the DeviceConfig out-of-tree driver ROCm version.
Precedence:
  1. .Values.driverVersion (explicit override injected by cluster-bloom)
  2. .Values.profiles[<family>].driverVersion for the selected gpuStackFamily
  3. the instinct profile (the current default)
Empty gpuStackFamily resolves to instinct, so existing installs are unchanged.
*/}}
{{- define "gpuStack.driverVersion" -}}
{{- if .Values.driverVersion -}}
{{- .Values.driverVersion -}}
{{- else -}}
{{- $family := .Values.gpuStackFamily | default "instinct" -}}
{{- $profile := index .Values.profiles $family | default (index .Values.profiles "instinct") -}}
{{- $profile.driverVersion -}}
{{- end -}}
{{- end -}}
