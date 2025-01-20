To deploy OpenObserve, Tools down below have to be deployed.
- OpenObserve-Collector (modified version of OpenTelemetry-Collector)
- OpenTelemetry-Operator
- Prometheus-CRDs


After deploying, OpenObserve is accessible by port-forwarding
`kubectl --namespace openobserve port-forward svc/o2-openobserve-standalone 5080:5080`


