{{- define "semantic-router-gateway.backendName" -}}
{{- . | lower | replace "/" "-" | replace "." "-" | replace "_" "-" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "semantic-router-gateway.host" -}}
{{- $parts := splitList ":" . -}}
{{- if lt (len $parts) 2 -}}
{{- fail (printf "endpoint %s must be <service>.<namespace>.svc.cluster.local:<port>" .) -}}
{{- end -}}
{{- index $parts 0 -}}
{{- end -}}

{{- define "semantic-router-gateway.port" -}}
{{- index (splitList ":" .) 1 -}}
{{- end -}}

{{- define "semantic-router-gateway.serviceName" -}}
{{- $host := include "semantic-router-gateway.host" . -}}
{{- index (splitList "." $host) 0 -}}
{{- end -}}

{{- define "semantic-router-gateway.serviceNamespace" -}}
{{- $host := include "semantic-router-gateway.host" . -}}
{{- $parts := splitList "." $host -}}
{{- if lt (len $parts) 2 -}}
{{- fail (printf "endpoint %s must be <service>.<namespace>.svc.cluster.local:<port>" .) -}}
{{- end -}}
{{- index $parts 1 -}}
{{- end -}}
