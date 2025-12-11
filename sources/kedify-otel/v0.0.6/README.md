# otel-add-on

![Version: v0.0.5](https://img.shields.io/badge/Version-v0.0.5-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: v0.0.5](https://img.shields.io/badge/AppVersion-v0.0.5-informational?style=flat-square)

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/otel-add-on)](https://artifacthub.io/packages/search?repo=otel-add-on)

A Helm chart for KEDA otel-add-on

```
:::^.     .::::^:     :::::::::::::::    .:::::::::.                   .^.
7???~   .^7????~.     7??????????????.   :?????????77!^.              .7?7.
7???~  ^7???7~.       ~!!!!!!!!!!!!!!.   :????!!!!7????7~.           .7???7.
7???~^7????~.                            :????:    :~7???7.         :7?????7.
7???7????!.           ::::::::::::.      :????:      .7???!        :7??77???7.
7????????7:           7???????????~      :????:       :????:      :???7?5????7.
7????!~????^          !77777777777^      :????:       :????:     ^???7?#P7????7.
7???~  ^????~                            :????:      :7???!     ^???7J#@J7?????7.
7???~   :7???!.                          :????:   .:~7???!.    ~???7Y&@#7777????7.
7???~    .7???7:      !!!!!!!!!!!!!!!    :????7!!77????7^     ~??775@@@GJJYJ?????7.
7???~     .!????^     7?????????????7.   :?????????7!~:      !????G@@@@@@@@5??????7:
::::.       :::::     :::::::::::::::    .::::::::..        .::::JGGGB@@@&7:::::::::
        _       _               _     _                               ?@@#~
   ___ | |_ ___| |     __ _  __| | __| |     ___  _ __                P@B^
  / _ \| __/ _ \ |    / _` |/ _` |/ _` |___ / _ \| '_ \             :&G:
 | (_) | ||  __/ |   | (_| | (_| | (_| |___| (_) | | | |            !5.
  \___/ \__\___|_|    \__,_|\__,_|\__,_|    \___/|_| |_|            ,
                                                                    .
```

**Homepage:** <https://github.com/kedify/otel-add-on>

## Usage

Check available version in OCI repo:
```
crane ls ghcr.io/kedify/charts/otel-add-on | grep -E '^v?[0-9]'
```

Install specific version:
```
helm upgrade -i oci://ghcr.io/kedify/charts/otel-add-on --version=v0.0.5
```

## Source Code

* <https://github.com/kedify/otel-add-on>
* <https://github.com/open-telemetry/opentelemetry-helm-charts>

## Requirements

Kubernetes: `>= 1.19.0-0`

| Repository | Name | Version |
|------------|------|---------|
| https://open-telemetry.github.io/opentelemetry-helm-charts | opentelemetry-collector | 0.110.0 |

## OTel Collector Sub-Chart

This helm chart, if not disabled by `--set opentelemetry-collector.enabled=false`, installs the OTel collector using
its upstream [helm chart](https://github.com/open-telemetry/opentelemetry-helm-charts/tree/main/charts/opentelemetry-collector).

To check all the possible values for this dependent helm chart, consult [values.yaml](https://github.com/open-telemetry/opentelemetry-helm-charts/blob/main/charts/opentelemetry-collector/values.yaml)
or [docs](https://github.com/open-telemetry/opentelemetry-helm-charts/blob/main/charts/opentelemetry-collector/README.md).

## Values

## Values

<table>
     <thead>
          <th>Key</th>
          <th>Description</th>
          <th>Default</th>
     </thead>
     <tbody>
          <tr>
               <td id="image--repository">
               <a href="./values.yaml#L8">image.repository</a><br/>
               (string)
               </td>
               <td>
               Image to use for the Deployment
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
"ghcr.io/kedify/otel-add-on"
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="image--pullPolicy">
               <a href="./values.yaml#L10">image.pullPolicy</a><br/>
               (string)
               </td>
               <td>
               Image pull policy, consult <a href="https://kubernetes.io/docs/concepts/containers/images/#image-pull-policy">docs</a>
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
"Always"
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="image--tag">
               <a href="./values.yaml#L12">image.tag</a><br/>
               (string)
               </td>
               <td>
               Image version to use for the Deployment, if not specified, it defaults to <code>.Chart.AppVersion</code>
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
""
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="settings--metricStore--retentionSeconds">
               <a href="./values.yaml#L17">settings.metricStore.retentionSeconds</a><br/>
               (int)
               </td>
               <td>
               how long the metrics should be kept in the short term (in memory) storage
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
120
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="settings--metricStore--lazySeries">
               <a href="./values.yaml#L21">settings.metricStore.lazySeries</a><br/>
               (bool)
               </td>
               <td>
               if enabled, no metrics will be stored until there is a request for such metric from KEDA operator.
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
false
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="settings--metricStore--lazyAggregates">
               <a href="./values.yaml#L25">settings.metricStore.lazyAggregates</a><br/>
               (bool)
               </td>
               <td>
               if enabled, the only aggregate that will be calculated on the fly is the one referenced in the metric query  (by default, we calculate and store all of them - sum, rate, min, max, etc.)
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
false
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="settings--isActivePollingIntervalMilliseconds">
               <a href="./values.yaml#L28">settings.isActivePollingIntervalMilliseconds</a><br/>
               (int)
               </td>
               <td>
               how often (in milliseconds) should the IsActive method be tried
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
500
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="settings--internalMetricsPort">
               <a href="./values.yaml#L31">settings.internalMetricsPort</a><br/>
               (int)
               </td>
               <td>
               internal (mostly golang) metrics will be exposed on <code>:8080/metrics</code>
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
8080
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="settings--restApiPort">
               <a href="./values.yaml#L34">settings.restApiPort</a><br/>
               (int)
               </td>
               <td>
               port where rest api should be listening
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
9090
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="settings--logs--logLvl">
               <a href="./values.yaml#L39">settings.logs.logLvl</a><br/>
               (string)
               </td>
               <td>
               Can be one of 'debug', 'info', 'error', or any integer value > 0 which corresponds to custom debug levels of increasing verbosity
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
"info"
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="settings--logs--stackTracesLvl">
               <a href="./values.yaml#L42">settings.logs.stackTracesLvl</a><br/>
               (string)
               </td>
               <td>
               one of: info, error, panic
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
"error"
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="settings--logs--noColor">
               <a href="./values.yaml#L45">settings.logs.noColor</a><br/>
               (bool)
               </td>
               <td>
               if anything else than 'false', the log will not contain colors
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
false
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="settings--logs--noBanner">
               <a href="./values.yaml#L48">settings.logs.noBanner</a><br/>
               (bool)
               </td>
               <td>
               if anything else than 'false', the log will not print the ascii logo
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
false
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="validatingAdmissionPolicy--enabled">
               <a href="./values.yaml#L52">validatingAdmissionPolicy.enabled</a><br/>
               (bool)
               </td>
               <td>
               whether the ValidatingAdmissionPolicy and ValidatingAdmissionPolicyBinding resources should be also rendered
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
true
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="asciiArt">
               <a href="./values.yaml#L56">asciiArt</a><br/>
               (bool)
               </td>
               <td>
               should the ascii logo be printed when this helm chart is installed
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
true
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="imagePullSecrets">
               <a href="./values.yaml#L59">imagePullSecrets</a><br/>
               (list)
               </td>
               <td>
               <a href="https://kubernetes.io/docs/concepts/containers/images/#specifying-imagepullsecrets-on-a-pod">details</a>
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
[]
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="serviceAccount--create">
               <a href="./values.yaml#L65">serviceAccount.create</a><br/>
               (bool)
               </td>
               <td>
               should the service account be also created and linked in the deployment
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
true
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="serviceAccount--annotations">
               <a href="./values.yaml#L68">serviceAccount.annotations</a><br/>
               (object)
               </td>
               <td>
               further custom annotation that will be added on the service account
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
{}
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="serviceAccount--name">
               <a href="./values.yaml#L70">serviceAccount.name</a><br/>
               (string)
               </td>
               <td>
               name of the service account, defaults to <code>otel-add-on.fullname</code> ~ release name if not overriden
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
""
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="podAnnotations">
               <a href="./values.yaml#L73">podAnnotations</a><br/>
               (object)
               </td>
               <td>
               additional custom pod annotations that will be used for pod
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
{}
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="podLabels">
               <a href="./values.yaml#L76">podLabels</a><br/>
               (object)
               </td>
               <td>
               additional custom pod labels that will be used for pod
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
{}
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="podSecurityContext">
               <a href="./values.yaml#L79">podSecurityContext</a><br/>
               (object)
               </td>
               <td>
               <a href="https://kubernetes.io/docs/tasks/configure-pod-container/security-context/#set-the-security-context-for-a-pod">details</a>
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
{}
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="securityContext--readOnlyRootFilesystem">
               <a href="./values.yaml#L86">securityContext.readOnlyRootFilesystem</a><br/>
               (bool)
               </td>
               <td>
               <a href="https://kubernetes.io/docs/tasks/configure-pod-container/security-context/">details</a>
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
true
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="securityContext--runAsNonRoot">
               <a href="./values.yaml#L88">securityContext.runAsNonRoot</a><br/>
               (bool)
               </td>
               <td>
               <a href="https://kubernetes.io/docs/tasks/configure-pod-container/security-context/#implicit-group-memberships-defined-in-etc-group-in-the-container-image">details</a>
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
true
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="securityContext--runAsUser">
               <a href="./values.yaml#L90">securityContext.runAsUser</a><br/>
               (int)
               </td>
               <td>
               <a href="https://kubernetes.io/docs/tasks/configure-pod-container/security-context/#implicit-group-memberships-defined-in-etc-group-in-the-container-image">details</a>
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
1000
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="service--type">
               <a href="./values.yaml#L95">service.type</a><br/>
               (string)
               </td>
               <td>
               Under this service, the otel add on needs to be reachable by KEDA operator and OTel collector (<a href="https://kubernetes.io/docs/concepts/services-networking/service/#publishing-services-service-types">details</a>)
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
"ClusterIP"
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="service--otlpReceiverPort">
               <a href="./values.yaml#L97">service.otlpReceiverPort</a><br/>
               (int)
               </td>
               <td>
               OTLP receiver will be opened on this port. OTel exporter configured in the OTel collector needs to have this value set.
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
4317
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="service--kedaExternalScalerPort">
               <a href="./values.yaml#L99">service.kedaExternalScalerPort</a><br/>
               (int)
               </td>
               <td>
               KEDA external scaler will be opened on this port. ScaledObject's <code>.spec.triggers[].metadata.scalerAddress</code> needs to be set to this svc and this port.
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
4318
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="resources--limits--cpu">
               <a href="./values.yaml#L104">resources.limits.cpu</a><br/>
               (string)
               </td>
               <td>
               cpu limit for the pod, enforced by cgroups (<a href="https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/">details</a>)
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
"500m"
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="resources--limits--memory">
               <a href="./values.yaml#L106">resources.limits.memory</a><br/>
               (string)
               </td>
               <td>
               memory limit for the pod, used by oomkiller (<a href="https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/">details</a>)
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
"256Mi"
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="resources--requests--cpu">
               <a href="./values.yaml#L109">resources.requests.cpu</a><br/>
               (string)
               </td>
               <td>
               cpu request for the pod, used by k8s scheduler (<a href="https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/">details</a>)
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
"500m"
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="resources--requests--memory">
               <a href="./values.yaml#L111">resources.requests.memory</a><br/>
               (string)
               </td>
               <td>
               memory request for the pod, used by k8s scheduler (<a href="https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/">details</a>)
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
"128Mi"
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="nodeSelector">
               <a href="./values.yaml#L125">nodeSelector</a><br/>
               (object)
               </td>
               <td>
               <a href="https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/#nodeselector">details</a>
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
{}
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="tolerations">
               <a href="./values.yaml#L128">tolerations</a><br/>
               (list)
               </td>
               <td>
               <a href="https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/">details</a>
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
[]
</pre>
</div>
               </td>
          </tr>
          <tr>
               <td id="affinity">
               <a href="./values.yaml#L131">affinity</a><br/>
               (object)
               </td>
               <td>
               <a href="https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/#affinity-and-anti-affinity">details</a>
               </td>
               <td>
                    <div style="max-width: 200px;">
<pre lang="json">
{}
</pre>
</div>
               </td>
          </tr>
     </tbody>
</table>

<!-- uncomment this for markdown style (use either valuesTableHtml or valuesSection)
(( template "chart.valuesSection" . )) -->
