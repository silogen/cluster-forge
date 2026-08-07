 Plan: OpenShift as a First-Class Citizen in cluster-forge

 Context

 The OpenShift installation path currently exists as a 2,013-line standalone script at
 docs/openshift/install.sh with supporting manifests in docs/openshift/extra/. These
 are not included in the release tarball (which packages root/ scripts/ sources only),
 not validated by CI, and not integrated into the GitOps configuration system that governs
 small/medium/large clusters. The goal is to make openshift a proper platform overlay,
 parallel to the size overlays (values_small.yaml, values_medium.yaml, values_large.yaml),
 so that OpenShift gets release artifact coverage, CI validation, and a path through
 cluster-bloom rather than a separate 40-step hand-rolled script.

 ---
 Overlay Model: global.platform (second axis, orthogonal to size)

 Rather than creating values_large_openshift.yaml etc., add a second merge axis:

 yq eval-all '. as $item ireduce ({}; . * $item)' \
   values.yaml values_<size>.yaml values_openshift.yaml

 Bootstrap invocation:
 ./scripts/bootstrap.sh example.com --cluster-size=large --platform=openshift

 This composes without combinatorial explosion. Size controls resources/replicas;
 platform controls which apps are enabled and how networking/security works.

 ---
 Phase 1: Move OpenShift manifests into sources/ (release tarball coverage)

 1a. sources/kyverno-policies/openshift/

 New Helm chart following the pattern of sources/kyverno-policies/base/.

 Templates (migrated from docs/openshift/extra/):
 - scc-generator.yaml ← kyverno-scc-for-ns.yaml
 - httproute-to-route.yaml ← kyverno-httproute-to-route-non-rewrite-policy.yaml
 - httproute-to-route-rewrite.yaml ← kyverno-httproute-to-route-rewrite-policy.yaml
 - scc-cleanup.yaml ← kyverno-cleanup-policy.yaml
 - route-rbac.yaml ← kyverno-route-permissions.yaml

 Replace sed -i s/<DOMAIN>/... substitutions with {{ .Values.global.domain }}.

 Requires test/ directory following kyverno-policies/base/test/ pattern:
 - kyverno-test.yaml
 - test-namespace-with-project-label.yaml (Namespace with airm.silogen.ai/project-id)
 - test-httproute-no-rewrite.yaml
 - test-httproute-rewrite.yaml

 CI watchpoint: ClusterCleanupPolicy uses kyverno.io/v2alpha1. The yq extraction
 in helm-chart-checks.yaml currently filters only kyverno.io/v1. Must widen to also
 capture kyverno.io/v2 and kyverno.io/v2alpha1. Cleanup policies are excluded from
 kyverno test results (not well-supported by CLI); validate them via helm lint only.

 1b. sources/openshift-config/

 New Helm chart for cluster-scoped OpenShift objects that are not Kyverno policies.

 Templates:
 - scc.yaml — 10 custom SCCs from docs/openshift/extra/scc.yaml (static, no Helm templating needed)
 - routes.yaml — 3 Routes (AIWB UI/API, Keycloak), parameterized with {{ .Values.global.domain }}
 - kyverno-reports-controller-rbac.yaml — ClusterRoleBinding that grants kyverno-reports-controller cluster-reader
 (currently inlined in install.sh)

 IngressController patch (routeAdmission.namespaceOwnership: InterNamespaceAllowed):
 Cannot be expressed as a static manifest. Recommendation for phase 1: document as a
 pre-flight prerequisite. Track as follow-up to implement via a Kubernetes Job with RBAC.

 Chart.yaml values.yaml with global.domain: "".

 syncWave: -25 (must run before kyverno-policies-openshift at -20 so SCCs exist before pods).

 1c. sources/openshift-gpu/

 Thin chart wrapping docs/openshift/extra/amd-gpu-nodefeaturerule.yaml only.
 No domain templating needed. syncWave: -5.

 ---
 Phase 2: Create root/values_openshift.yaml

 Follow the same pattern as values_small.yaml. Key decisions:

 Disabled apps (OpenShift provides native equivalents):
 - metallb — OpenShift has its own LB
 - envoy-gateway, envoy-gateway-config, envoy-ai-gateway, envoy-ai-gateway-crds, inference-extension-crds
 - gateway-api-crds — skip by default on OpenShift
 - kyverno-policies-storage-local-path — OpenShift clusters should have proper storage

 New OpenShift-specific apps (defined only in this file):
 - kyverno-policies-openshift → sources/kyverno-policies/openshift
 - openshift-config → sources/openshift-config
 - openshift-gpu-nfr → sources/openshift-gpu

 App-level overrides in values_openshift.yaml:
 - kyverno: increase reportsController memory limits (OOM risk on OpenShift)
 - argocd: add custom health check for route.openshift.io/v1 Route (ArgoCD marks them Unknown otherwise)
 - otel-lgtm-stack: shift node-exporter metrics port from 9100 → 9101 (conflicts with OpenShift built-in
 cluster-monitoring)

 Note on enabledApps merge semantics: Because yq * deep-merge replaces arrays,
 values_openshift.yaml must carry its complete desired enabledApps list (same as
 values_small.yaml and values_medium.yaml do today). The OpenShift overlay wins the
 array, which is correct — it controls which apps are valid for this platform.

 App definitions for the three new OpenShift apps should live in values_openshift.yaml
 itself, not in values.yaml. They are meaningless on vanilla Kubernetes, and the template
 only validates enabled apps against the apps map, so as long as both keys appear in the
 same merge result, the required check passes.

 ---
 Phase 3: Update root/templates/cluster-forge.yaml

 Add optional second values file for global.platform:

 valueFiles:
   - {{ .Values.clusterForge.valuesFile }}
   {{- if .Values.global.clusterSize }}
   - {{ .Values.global.clusterSize }}
   {{- end }}
   {{- if .Values.global.platform }}
   - {{ .Values.global.platform }}         # e.g. values_openshift.yaml
   {{- end }}

 Add global.platform: null to root/values.yaml global section.

 ---
 Phase 4: CI updates (helm-chart-checks.yaml)

 1. Root chart matrix: add ./root/values_openshift.yaml
 2. Kyverno policies matrix: add ./sources/kyverno-policies/openshift
 3. EXPECTED_CHARTS in kyverno-coverage-check: add the new path
 4. Fix yq extraction: widen select(.apiVersion == "kyverno.io/v1") to include kyverno.io/v2 and
 kyverno.io/v2alpha1
 5. New job openshift-charts: helm lint + helm template on sources/openshift-config and sources/openshift-gpu with
 --set global.domain=example.com
 6. New job root-chart-combined: validate merged values.yaml + values_large.yaml + values_openshift.yaml to confirm
  the two overlay axes compose without conflict
 7. pr-component-validation.yaml: add root/values_openshift.yaml to path filter

 No release-pipeline.yaml changes needed: the tarball already captures all of root/ and sources/ recursively. The
 new files are automatically included.

 ---
 Phase 5: Refactor docs/openshift/install.sh

 Target state: thin bootstrap wrapper, not a 40-step reimplementation.

 Keep in script (Phase A — bootstrap):
 - Download release tarball
 - Remove hardcoded CLUSTER_FORGE_VERSION=v2.2.0 default; require caller to set it
 - Apply openshift-config SCCs early (before ArgoCD starts scheduling pods)
 - Bootstrap ArgoCD + OpenBao + Gitea (same as cluster-bloom's deploy_clusterforge role)
 - Create cluster-forge Application in ArgoCD with merged values_<size>.yaml + values_openshift.yaml
 - Wait for ArgoCD health

 Remove from script (Phase B — now in GitOps):
 - All per-app helm template | kubectl apply steps (steps 4–38)
 - On-the-fly patches (sed substitutions, SeaweedFS HOME=/tmp fix — track as upstream bug in
 sources/seaweedfs-config)
 - Envoy failOpen patch (irrelevant since Envoy Gateway is disabled on OpenShift)

 The PLUGGABLE_DB and PLUGGABLE_S3 flags should map to Helm values in values_openshift.yaml rather than branching
 script logic.

 This is a significant refactor. For the initial ticket, scope it as: remove the Envoy patch, remove hardcoded
 version default, and add a comment header on each step block pointing to the corresponding values_openshift.yaml
 app entry. Full delegation to GitOps is a follow-up.

 ---
 Thin chart wrapping docs/openshift/extra/amd-gpu-nodefeaturerule.yaml only.
 No domain templating needed. syncWave: -5.

 ---
 Phase 2: Create root/values_openshift.yaml

 Follow the same pattern as values_small.yaml. Key decisions:

 Disabled apps (OpenShift provides native equivalents):
 - metallb — OpenShift has its own LB
 - envoy-gateway, envoy-gateway-config, envoy-ai-gateway, envoy-ai-gateway-crds, inference-extension-crds
 - gateway-api-crds — skip by default on OpenShift
 - kyverno-policies-storage-local-path — OpenShift clusters should have proper storage

 New OpenShift-specific apps (defined only in this file):
 - kyverno-policies-openshift → sources/kyverno-policies/openshift
 - openshift-config → sources/openshift-config
 - openshift-gpu-nfr → sources/openshift-gpu

 App-level overrides in values_openshift.yaml:
 - kyverno: increase reportsController memory limits (OOM risk on OpenShift)
 - argocd: add custom health check for route.openshift.io/v1 Route (ArgoCD marks them Unknown otherwise)
 - otel-lgtm-stack: shift node-exporter metrics port from 9100 → 9101 (conflicts with OpenShift built-in
 cluster-monitoring)

 Note on enabledApps merge semantics: Because yq * deep-merge replaces arrays,
 values_openshift.yaml must carry its complete desired enabledApps list (same as
 values_small.yaml and values_medium.yaml do today). The OpenShift overlay wins the
 array, which is correct — it controls which apps are valid for this platform.

 App definitions for the three new OpenShift apps should live in values_openshift.yaml
 itself, not in values.yaml. They are meaningless on vanilla Kubernetes, and the template
 only validates enabled apps against the apps map, so as long as both keys appear in the
 same merge result, the required check passes.

 ---
 Phase 3: Update root/templates/cluster-forge.yaml

 Add optional second values file for global.platform:

 valueFiles:
   - {{ .Values.clusterForge.valuesFile }}
   {{- if .Values.global.clusterSize }}
   - {{ .Values.global.clusterSize }}
   {{- end }}
   {{- if .Values.global.platform }}
   - {{ .Values.global.platform }}         # e.g. values_openshift.yaml
   {{- end }}

 Add global.platform: null to root/values.yaml global section.

 ---
 Phase 4: CI updates (helm-chart-checks.yaml)

 1. Root chart matrix: add ./root/values_openshift.yaml
 2. Kyverno policies matrix: add ./sources/kyverno-policies/openshift
 3. EXPECTED_CHARTS in kyverno-coverage-check: add the new path
 4. Fix yq extraction: widen select(.apiVersion == "kyverno.io/v1") to include kyverno.io/v2 and
 kyverno.io/v2alpha1
 5. New job openshift-charts: helm lint + helm template on sources/openshift-config and sources/openshift-gpu with
 --set global.domain=example.com
 6. New job root-chart-combined: validate merged values.yaml + values_large.yaml + values_openshift.yaml to confirm
  the two overlay axes compose without conflict
 7. pr-component-validation.yaml: add root/values_openshift.yaml to path filter

 No release-pipeline.yaml changes needed: the tarball already captures all of root/ and sources/ recursively. The
 new files are automatically included.

 ---
 Phase 5: Refactor docs/openshift/install.sh

 Target state: thin bootstrap wrapper, not a 40-step reimplementation.

 Keep in script (Phase A — bootstrap):
 - Download release tarball
 - Remove hardcoded CLUSTER_FORGE_VERSION=v2.2.0 default; require caller to set it
 - Apply openshift-config SCCs early (before ArgoCD starts scheduling pods)
 - Bootstrap ArgoCD + OpenBao + Gitea (same as cluster-bloom's deploy_clusterforge role)
 - Create cluster-forge Application in ArgoCD with merged values_<size>.yaml + values_openshift.yaml
 - Wait for ArgoCD health

 Remove from script (Phase B — now in GitOps):
 - All per-app helm template | kubectl apply steps (steps 4–38)
 - On-the-fly patches (sed substitutions, SeaweedFS HOME=/tmp fix — track as upstream bug in
 sources/seaweedfs-config)
 - Envoy failOpen patch (irrelevant since Envoy Gateway is disabled on OpenShift)

 The PLUGGABLE_DB and PLUGGABLE_S3 flags should map to Helm values in values_openshift.yaml rather than branching
 script logic.

 This is a significant refactor. For the initial ticket, scope it as: remove the Envoy patch, remove hardcoded
 version default, and add a comment header on each step block pointing to the corresponding values_openshift.yaml
 app entry. Full delegation to GitOps is a follow-up.

 ---
 Phase 6: SBOM updates

 - Add values_openshift.yaml to sbom/validate-enabled-apps.sh file list
 - Add kyverno-policies-openshift and openshift-gpu-nfr entries to sbom/components.yaml
 (openshift-config is a -config suffix chart and will be auto-excluded per existing SBOM rules)

 ---
 Phase 7: Documentation

 - Update docs/openshift/README.md: reflect new GitOps path, note that docs/openshift/extra/ manifests have moved
 to sources/
 - Update docs/cluster_size_configuration.md: document the global.platform dimension
 - Update docs/values_inheritance_pattern.md: add OpenShift row to the inheritance table

 ---
 Critical Files

 ┌────────────────────────────────────────────────┬─────────────────────────────────────────────────────────────┐
 │                      File                      │                           Action                            │
 ├────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
 │ root/values_openshift.yaml                     │ Create (new platform overlay)                               │
 ├────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
 │ root/values.yaml                               │ Modify (add global.platform: null)                          │
 ├────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
 │ root/templates/cluster-forge.yaml              │ Modify (add global.platform valueFile injection)            │
 ├────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
 │ sources/kyverno-policies/openshift/            │ Create (new Helm chart + test harness)                      │
 ├────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
 │ sources/openshift-config/                      │ Create (SCCs, Routes, RBAC)                                 │
 ├────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
 │ sources/openshift-gpu/                         │ Create (AMD GPU NFD fallback)                               │
 ├────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
 │ .github/workflows/helm-chart-checks.yaml       │ Modify (new matrices, fix yq extraction, new jobs)          │
 ├────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
 │ .github/workflows/pr-component-validation.yaml │ Modify (add path filter)                                    │
 ├────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
 │ sbom/components.yaml                           │ Modify (add new chart entries)                              │
 ├────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
 │ sbom/validate-enabled-apps.sh                  │ Modify (add values_openshift.yaml)                          │
 ├────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
 │ docs/openshift/install.sh                      │ Modify (remove hardcoded version, remove Envoy patch, slim  │
 │                                                │ steps)                                                      │
 ├────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
 │ docs/openshift/README.md                       │ Modify (update to reflect GitOps path)                      │
 └────────────────────────────────────────────────┴─────────────────────────────────────────────────────────────┘

 ---
 Verification (no real OpenShift cluster required)

 1. helm lint ./root -f root/values_openshift.yaml — platform overlay renders clean
 2. yq eval-all merge | helm lint ./root -f /tmp/merged.yaml — large+openshift combination is valid
 3. kyverno test sources/kyverno-policies/openshift/test/ — policy logic correct against stubs
 4. helm lint sources/openshift-config --set global.domain=test.example.com — SCC/Route YAML valid
 5. helm template test sources/openshift-config --set global.domain=test.example.com — renders without error
 6. CI passes on PR (all jobs in helm-chart-checks.yaml green)

 End-to-end validation on a real OpenShift cluster is a separate acceptance gate.

 ---
 Jira Ticket (to be created via /backlog)

 See task below.
