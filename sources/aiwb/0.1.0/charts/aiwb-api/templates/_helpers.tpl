# Copyright © Advanced Micro Devices, Inc., or its affiliates.
#
# SPDX-License-Identifier: MIT

{{/*
Construct the keycloak public URL for AIWB to use.
Use .Values.aiwb.keycloak.publicUrl if specified, otherwise construct from known values.
*/}}
{{- define "aiwb-api.keycloakPublicUrl" -}}
{{- if .Values.aiwb.keycloak.publicUrl -}}
{{ .Values.aiwb.keycloak.publicUrl }}
{{- else -}}
https://kc.{{ .Values.aiwb.appDomain }}
{{- end -}}
{{- end -}}
