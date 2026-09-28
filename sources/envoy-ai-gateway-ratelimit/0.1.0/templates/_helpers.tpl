{{- define "envoy-ai-gateway-ratelimit.redisURL" -}}
{{- if .Values.redis.enabled -}}
envoy-ai-gateway-ratelimit-redis.envoy-gateway-system.svc:6379
{{- else -}}
{{- required "redis.url is required when redis.enabled is false" .Values.redis.url -}}
{{- end -}}
{{- end -}}

{{- define "envoy-ai-gateway-ratelimit.redisAuthSecretRef" -}}
name: {{ required "redis.auth.existingSecret is required when redis.auth.enabled is true" .Values.redis.auth.existingSecret }}
key: {{ .Values.redis.auth.existingSecretPasswordKey }}
{{- end -}}
