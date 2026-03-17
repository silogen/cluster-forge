# Copyright © Advanced Micro Devices, Inc., or its affiliates.
#
# SPDX-License-Identifier: MIT

{{/*
Construct the keycloak public URL for AIRM to use.
Use .Values.airm.keycloak.publicUrl if specified, otherwise construct from known values.
*/}}
{{- define "airm-api.keycloakPublicUrl" -}}
{{- if .Values.airm.keycloak.publicUrl -}}
{{ .Values.airm.keycloak.publicUrl }}
{{- else -}}
https://{{ .Values.kgateway.keycloak.prefixValue }}.{{ .Values.airm.appDomain }}
{{- end -}}
{{- end -}}
