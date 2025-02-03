[1 Quickstart guide 2](#quickstart-guide)

[2 Server Setup 3](#server-setup)

[2.1 Connectivity and Prerequisites for the cluster installation
3](#connectivity-and-prerequisites-for-the-cluster-installation)

[2.2 Installation of ROCM drivers 3](#installation-of-rocm-drivers)

[2.3 Deploy a high-availability RKE2 cluster using Ansible
3](#deploy-a-high-availability-rke2-cluster-using-ansible)

[3 Installing Components on the Kubernetes Cluster
4](#installing-components-on-the-kubernetes-cluster)

[3.1 Installation from ClusterForge release
4](#installation-from-clusterforge-release)

[4 Installation of Kaiwo CLI tool 5](#installation-of-kaiwo-cli-tool)

[5 Working with Workloads 6](#working-with-workloads)

[5.1 Prerequisites 6](#prerequisites)

[5.2 LLM Inference Workloads 6](#llm-inference-workloads)

[5.2.1 Inference with vLLM 6](#inference-with-vllm)

[5.2.2 vLLM-Based Offline Batch Inference
7](#vllm-based-offline-batch-inference)

[5.2.3 vLLM-Based Online Batch Inference
8](#vllm-based-online-batch-inference)

[5.3 LLM Training Workloads 8](#llm-training-workloads)

[5.3.1 Simple example to train a Bert model on a classification task
8](#simple-example-to-train-a-bert-model-on-a-classification-task)

[5.3.2 Single and Multi-Node full-parameter training
8](#single-and-multi-node-full-parameter-training)

[5.3.3 Lora supervised fine-tuning 9](#lora-supervised-fine-tuning)

[Appendix 10](#appendix)

[Appendix A. Using ClusterForge 10](#appendix-a.-using-clusterforge)

[Overview of Component Configuration Process with ClusterForge
11](#overview-of-component-configuration-process-with-clusterforge)

[Adding new components to install with ClusterForge
11](#adding-new-components-to-install-with-clusterforge)

[ClusterForge smelt step 12](#clusterforge-smelt-step)

[Adding variable templates 13](#adding-variable-templates)

[ClusterForge cast step 13](#clusterforge-cast-step)

[Setting values for templated variables
15](#setting-values-for-templated-variables)

[Ephemeral Stack with ClusterForge Forge step
16](#ephemeral-stack-with-clusterforge-forge-step)

[Deploying the Stack 16](#deploying-the-stack)

[**Appendix B**. Using Kaiwo 16](#appendix-b.-using-kaiwo)

[Usage 16](#usage)

[Deploying with Kaiwo 17](#deploying-with-kaiwo)

[Note about environment variables 18](#note-about-environment-variables)

[Enabling auto-completion for Kaiwo
18](#enabling-auto-completion-for-kaiwo)

[Workload Templates 19](#workload-templates)

[**Appendix C**. LLM Tokens 19](#appendix-c.-llm-tokens)

[What is a Hugging Face Token? 19](#what-is-a-hugging-face-token)

[Why Do You Need to Install It as a Secret?
19](#why-do-you-need-to-install-it-as-a-secret)

[How to Get a Hugging Face Token 20](#how-to-get-a-hugging-face-token)

[Where to Install the Token 20](#where-to-install-the-token)

# Quickstart guide

This handbook provides instructions for installing components into a
Kubernetes cluster and running AI workloads efficiently in a cluster of
multiple AMD GPUs. Specifically, this handbook presents how to use the
tools provided by the **SiloGen Enterprise AI Platform** to perform
these operations in a repeatable way.

If you are starting from bare metal with a Linux operating system such
as Ubuntu 22.04 installed, there are a few manual steps to bring up a
Kubernetes cluster and install needed tools and dependencies, which are
described in [Section 2](#server-setup) and [Section
3](#installing-components-on-the-kubernetes-cluster), respectively. If
the cluster is already up and running with all the components, [Section
4](#working-with-workloads) gives instructions to install a command line
interface for running and benchmarking various AI workloads in the
cluster. When all the tools are in place, [Section
5](#working-with-workloads) provides guidance and examples of working
with workloads. More information and links are given in the
[*Appendix*](#appendix).

Steps outlined to run AI workloads outlined in this guide. If a
Kubernetes cluster is already in place one may skip to step 4.

1.  [Connectivity and
    Prerequisites](#connectivity-and-prerequisites-for-the-cluster-installation)

2.  [Install ROCm Drivers](#installation-of-rocm-drivers)

3.  [Deploy a high-availability Kubernetes
    cluster](#deploy-a-high-availability-rke2-cluster-using-ansible)

4.  [Deploy the needed tools for running and
    monitoring](#installing-components-on-the-kubernetes-cluster)

5.  [Working with workloads](#working-with-workloads)

# Server Setup

This chapter describes how to set up a Kubernetes cluster on top of the
HW nodes, with a Linux operating system such as Ubuntu 22.04 installed.

## Connectivity and Prerequisites for the cluster installation 

-   Ansible must be installed on the installer's laptop

-   An SSH key must be added to the servers and matches the key in
    ansible.cfg

-   The IP addresses/FQDNs of the GPU servers are updated in an
    inventory.ini file, example is provided in the ansible directory of
    the release package
```
[master]
mi300-node1 ansible_host=mi300-node1 internal_ip=10.0.0.141
[worker]
mi300-node2 ansible_host=mi300-node2 internal_ip=10.0.0.142
```

+-----------------------------------------------------------------------+

The ansible scripts are provided in a ClusterForge release package.

Download and unzip the latest release from
<https://github.com/silogen/cluster-forge/releases>. As of 2025 Jan 28,
the latest release is ClusterForge1.0.0

See the contents of the release in the directory clusterforge/ of the
unzipped package.

## Installation of ROCM drivers

In clusterforge/ansible directory of the release run the following
command:

```
ansible-playbook -i inventory.ini install-rocm-host-driver.yaml
```

## Deploy a high-availability RKE2 cluster using Ansible

In clusterforge/ansible directory of the ClusterForge package, run the
following command:

```
ansible-playbook -i inventory.ini rke2_single_master.yaml
```

The playbook will install RKE2 on the servers and configure a
high-availability cluster. It will also fetch the kubeconfig file from
the first server and save it in your present working directory as
kubeconfig_rke2.yaml. You can use this file to access the cluster using
kubectl after running.\
\
Note that the playbook will attempt to uninstall any existing rke2 if
present, and if not present a 'fatal:' error will popup in read and the
install will continue.

scp the KUBECONFIG from /etc/rancher/rke2/rke2.yaml to your local
machine.

Edit the server: <https://127.0.0.1:6443> to the hostname of the
master:6443

```
export KUBECONFIG=kubeconfig_rke2.yaml
```

# Installing Components on the Kubernetes Cluster

This section gives instructions for installing desired components on a
Kubernetes (K8s) cluster using the SiloGen Enterprise AI
**ClusterForge** tool**.**

```
  ____ _           _              _____
 / ___| |_   _ ___| |_ ___ _ __  |  ___|__  _ __ __ _  ___
| |   | | | | / __| __/ _ \ '__| | |_ / _ \| '__/ _` |/ _ \
| |___| | |_| \__ \ ||  __/ |    |  _| (_) | | | (_| |  __/
 \____|_|\__,_|___/\__\___|_|    |_|  \___/|_|  \__, |\___|
                                                |___/
```

ClusterForge is designed to be an easy way to install a stack of
components into a K8s cluster with a couple of commands.

The ClusterForge 0.1.0 release has the following services pre-installed:

-   **certmanger**

-   **external-secrets**

-   **amd-gpu-operator**

-   **amd-device-config**

-   **minio-operator**

-   **minio-tenant**

-   **kueue**

-   **kuberay-operator**

-   **kaiwo-cluster-config**

The deployment of the components configured in the ClusterForge will
need access to the K8s cluster API. If the code is run outside the
cluster, which is most often the case, the connection must be defined
with kubeconfig either in the default location .kube/config, or through
the KUBECONFIG environment variable. If neither of them is defined,
ClusterForge will assume the code to be running inside a Pod in a
cluster.

## Installation from ClusterForge release

Here we provide instructions to install a standard stack of components
using a released ClusterForge package. To customize the set of
components to install, please see the [Appendix
A](#appendix-a.-using-clusterforge).

To get the ClusterForge package, download and unzip the latest release
from <https://github.com/silogen/cluster-forge/releases>. As of 2025 Jan
15, the latest release is ClusterForge Baseline 0.1.0

After decompressing the ClusterForge package, run the following command
to install all the components into the K8s cluster:

```
cd clusterforge

bash deploy.sh
```

Finally, a notification as shown in **Figure 2** should be seen.

![](media/image2.png){width="4.08332895888014in"
height="0.70832895888014in"}

**Figure 2**. Notification of a successful deployment of components to
the K8s cluster.

# Installation of Kaiwo CLI tool

This section gives instructions for installing and using the **SiloGen
Enterprise AI** tool **Kaiwo.** For more detailed instructions on
general usage of Kaiwo, see [Appendix B](#_Appendix_B._Using).

<figure>
<img src="media/image3.png" style="width:3.5in;height:1in" />
<figcaption><p><strong>Figure</strong> 3<strong>.</strong> Kaiwo
logo.</p></figcaption>
</figure>

Kaiwo is an AI workload orchestrator tool designed for running AI
workloads like LLM inference and fine-tuning in a K8s cluster. It is
designed to minimize GPU idleness and increase resource efficiency
through intelligent job queueing, based on principles such as fair
sharing of resources, guaranteed quotas, and opportunistic batch job
scheduling.

The installation of Kaiwo CLI tool is a single binary. The prerequisites
are:

1.  A working [Kubernetes
    cluster](#deploy-a-high-availability-rke2-cluster-using-ansible)
    with GPUs

2.  Tools described in
    [ClusterForge](#installation-from-clusterforge-release)

3.  A [Huggingface token](#_Appendix_C._LLM_1)

Kaiwo will first look for a KUBECONFIG=path environment variable. If
KUBECONFIG is not set, Kubernetes will then look for kubeconfig file in
the default location \~/.kube/config.

1.  To install Kaiwo, download the Kaiwo CLI binary from the [Releases
    Page](https://github.com/silogen/kaiwo/releases).

2.  Make the binary executable and add it to your PATH

To do both steps in one command for Linux (AMD64), edit v.x.x.x in the
following and run it

```
wget https://github.com/silogen/kaiwo/releases/download/v.x.x.x/kaiwo_linux_amd64 && \\                                    mv kaiwo_linux_amd64 kaiwo && \\
chmod +x kaiwo &&
sudo mv kaiwo /usr/local/bin/

kaiwo \--help
```

3.  You\'re off to the races!

# Working with Workloads

This chapter describes how to run AI workloads using the Kubernetes AI
workload orchestrator tool called Kaiwo. Kaiwo provides a framework for
deploying and managing AI workloads on Kubernetes. It supports scenarios
like inference and training across single and multi-node setups. Refer
to model-specific documentation for dependencies such as external
secrets, managing GPU allocations, and understanding workload-specific
requirements. Below are examples of how to run various workloads with
Kaiwo, including the necessary commands and configurations.

## Prerequisites

Most of the workloads require a personal [Hugging Face
token](#_Appendix_C._LLM)

## LLM Inference Workloads

This section describes how to run different model inference workloads
using Kaiwo tool.

Inference is available in both online and offline variants.

### Inference with vLLM

Follow these steps to deploy the LLM Inference vLLM workload using
Kaiwo:

**Deploy with Kaiwo**:

```
kaiwo serve \--image rocm/vllm-dev:20241205-tuned \--path llm-inference-vllm/kaiwo/ \--gpus 1
```

**To Verify Deployment:** Check the deployment status:

```
kubectl get deployment -n kaiwo
```

**Port Forwarding:** Forward the port to access the service (assuming
the deployment is named ubuntu-kaiwo):

```
kubectl port-forward deployments/ubuntu-kaiwo 8080:8080 -n kaiwo
```

**Test the Deployment:** Send a test request to verify the service:

```
curl <http://localhost:8080/v1/chat/completions> \\
    -H \"Con-Type: application/json\" \\
    -d \'{\"model\": \"meta-llama/Llama-3.1-8B-Instruct\",
    \"messages\": \[{\"role\": \"system\", \"content\": \"You are a helpful
 assistant.\"},{\"role\": \"user\", \"content\": \"Who won the world
 series in 2020?\"} \]}\'
```

### vLLM-Based Offline Batch Inference

This workload example with Llama3 currently only supports single-node
inference (one model instance per node), but the workload can be scaled
to multiple instances by increasing num_instances

Note! this workload expects existing secrets. Have a look at env  file
for the expected secrets.

To run this workload on 16 GPUs in kaiwo namespace, you can let Kaiwo
automatically set env variables  NUM_GPUS_PER_REPLICA  to  8  and
 NUM_REPLICAS  to  2. Kaiwo is able to set these by inspecting the
number of requested GPUs (-g) and the number of GPUs available per node.
See main.py for more details how the training script uses these env
variables.

Run with:

```
kaiwo submit -p workloads/inference/LLMs/offline-inference/vllm-batch-single-multinode/ -g 16 --ray
```

Or set these variables yourself with the following command:

```kaiwo submit -p workloads/inference/LLMs/offline-inference/vllm-batch-single-multinode/ --replicas 2 --gpus-per-replica 8 --ray
```

### vLLM-Based Online Batch Inference

Supports single-node and multi-node inference

Note! this workload expects existing secrets. Have a look at env file
for the expected secrets.

Note also that currently multi-node setup (NUM_REPLICAS \> 1) requires
setting NCCL_P2P_DISABLE=1 which involves some performance penalty in
addition to the penalty introduced by network latency/bandwidth between
nodes. Do not set NCCL_P2P_DISABLE=1 for single-node setup.

To run this workload on 16 GPUs in kaiwo namespace, you can let Kaiwo
automatically set env variables NUM_GPUS_PER_REPLICA to 8 and
NUM_REPLICAS to 2. Kaiwo is able to set these by inspecting the number
of requested GPUs (-g) and the number of GPUs available per node. See
\_\_init\_\_.py for more details how the training script uses these env
variables.

Run with:

```
kaiwo serve -p workloads/inference/LLMs/online-inference/vllm-online-single-multinode -g 16 --ray
```

Or set these variables yourself with the following command:

```kaiwo serve -p workloads/inference/LLMs/online-inference/vllm-online-single-multinode --replicas 2 \--gpus-per-replica 8 --ray
```

## 

## LLM Training Workloads

This section describes how to run different model training workloads
using Kaiwo tool.

### Simple example to train a Bert model on a classification task

The \--gpus/-g flag is passed to the job as NUM_GPUS environment
variable in the entrypoint so you don\'t need to touch the entrypoint
when adding GPUs for training.

To run on 4 GPUs:

```
kaiwo submit -p workloads/training/LLMs/jobs/single-node-bert-train-classification -g 4
```

### 

### Single and Multi-Node full-parameter training

Dependencies:

-   hf-token: Hugging Face API token for model download

-   s3-secret: S3 secret for model upload or GCS secret for model
    upload - refactor env file and code accordingly

Note! this workload expects existing secrets for access to storage. Have
a look at env file for the expected secrets. If you find both S3 and GCS
secrets, you can choose to use either one. You\'ll need to add the
secret in a similar way as the Hugging Face token is applied.

-   full-parameter-pretraining

-   Supports single-node and multi-node scenarios

-   DeepSpeed ZeRO stage 3 partitions LLM parameters, gradients, and
    optimizer states across multiple GPUs

-   set num_devices to total number of GPUs.

To run this workload on 16 GPUs in kaiwo namespace, set num_devices in
entrypoint to 16 and use the following command:

```
kaiwo submit -p workloads/training/LLMs/ \\
    full-parameter-pretraining/ \\
    full-param-zero3-single-multinode -g 16 --ray
```

### Lora supervised fine-tuning

Dependencies:

-   hf-token: Hugging Face API token for model download

-   s3-secret: S3 secret for model upload or GCS secret for model
    upload - refactor env file and code accordingly

Note! this workload expects existing secrets. Have a look at env file
for the expected secrets. If you find both S3 and GCS secrets, you can
choose to use either one. Remember to refactor your code accordingly.

-   LORA finetuning: if you use a different model architecture, you may
    need to adjust LORA configuration and target_modules in particular.

-   Supports single-node and multi-node scenarios

-   DeepSpeed Zero stage 3 partitions LLM parameters, gradients, and
    optimizer states across multiple GPUs

-   set num_devices to total number of GPUs.

To run this workload on 16 GPUs in kaiwo namespace, set num_devices in
entrypoint to 16 and use the following command:

```
kaiwo submit -p workloads/training/LLMs/lora-supervised-finetuning/lora-sft-zero3-single-multinode -g 16 --ray
```

#  {#section-2 .Appendix}

# Appendix

## Appendix A. Using ClusterForge

This section provides instructions for how to install a stack of
components to a K8s cluster using the ClusterForge tool.

First, run the following command to download the ClusterForge tool:

```
git clone https://github.com/silogen/cluster-forge
cd cluster-forge
```

ClusterForge needs the following software to be installed and functional
before proceeding:

-   Kubectl (in line with your cluster setup)

-   Helm

-   Golang (v1.23 or higher)

-   Docker

-   Multi-Architecture Docker build

    -   (run: docker buildx create \--name multiarch-builder --use)

Currently ClusterForge has the following services configured and ready
to install out-of-the-box (Kaiwo Dependencies are **highlighted in
bold**):

-   **certmanager**

-   **amd-gpu-operator**

-   **amd-device-config**

-   grafana-gpu-dashboard

-   **kueue**

-   **external-secrets**

-   **external-secrets-cluster-secret-store**

-   psmdb-operator

-   cnpg-operator

-   kyverno-policies

-   kyverno

-   prometheus

-   promtail

-   **minio**

-   trivy

-   dummy-secret-monitoring-tools

-   grafana

-   **kuberay-operator**

-   **kaiwo-cluster-config**

Online links to the service packages listed above can be found in *Table
1* in [Appendix B](#_Appendix_B._External).

### Overview of Component Configuration Process with ClusterForge

The three main commands in ClusterForge are "Smelt", "Cast" and "Forge".
The "Smelt" step prepares initial manifests into the folder
cluster-forge/working. "Cast" packages the stack into a deployable image
and stores it in an image registry, defaulted to temporary public image
registry described in section A.6, or the registry of your choice
described in section A.5. "Forge" runs both smelt and cast, but will
store the stack image in an ephemeral and public image registry. This
can simplify testing and demoing but is not recommended for production
purposes yet.

**Note:** In case any previous custom configurations should be removed
from ClusterForge folders before working on a new stack, a cleaning
script shown below can be run to delete all previous prepared
configurations and log files. The script does not delete already
prepared, i.e. "cast" stacks.

```
sh cluster-forge/scripts/clean.sh
```

### Adding new components to install with ClusterForge

To add a new component for installation using ClusterForge, information
about the Helm source of the service must first be added into the file
/cluster-forge/input/ config.yaml. An example is given in Figure 4, and
you can see more examples in the actual file.

```
![A close-up of a computer screen Description automatically
generated](media/image4.png){width="6.5in"
height="1.3215299650043744in"}

**Figure 4**. Example of Helm source definition of a component for
ClusterForge in the file */cluster-forge/input/config.yaml.*

To add custom values for Helm templates for the new component, a values
yaml file should be added into a component specific folder with the path
specified as follows:

cluster-forge/input/\<component-name\>/\<component-values-file\>.yaml,

where \<component-name\> equals the name parameter, and
\<component-values\> equals the values parameter in the
cluster-forge/input/config.yaml file.

### ClusterForge smelt step

The ClusterForge "smelt" step is a preparatory step which downloads the
Helm charts of the components and prepares Kubernetes manifests for them
into the directory\
cluster-forge/working/**.**

To do the "smelt" step, run the following command in the ClusterForge
root directory cluster-forge/:

```
go run . smelt
```

<figure>
<img src="media/image5.png" style="width:4.71841in;height:2.8365in"
alt="A screenshot of a computer program Description automatically generated" />
<figcaption><p>Figure 5. View of selecting services to prepare during
the CF smelt step.</p></figcaption>
</figure>

The terminal will show a menu like the one seen in Figure 5. Type 'x' to
make the selection of components to prepare. Use the arrow keys to move
up and down and click 'enter' when the selection has been made. It is
possible to prepare all of the components in this step even if all of
them would not be selected for a stack to deploy.

Note: The minimum components to include for Kaiwo is: certmanager,
amd-gpu-operatorm amd-device-config, kueue, kyverno and
kuberay-operator.

Downloading the Helm charts and preparing the manifests can take some
time. In the end, you can find the prepared manifests in the
cluster-forge/working/ directory.

### Adding variable templates 

When a similar stack of components is needed for multiple K8s clusters,
variable templating makes it easy to configure a stack with few
cluster-dependent variables which are set during deployment.
ClusterForge enables this behavior with template strings like

{{ .observed.composite.resource.spec.\<variableName\> }}

where \<variableName\> is any alphanumeric name that you wish to use for
the variable. The string .observed.composite.resource.spec. is fixed and
should not be changed. This kind of template strings should be manually
added to manifests made by the "smelt" step into the
cluster-forge/working/ directory. Figure 6 shows an example of a
manifest file, where templating has been used for spec.storageClassName.
A value for the variable storageClass will be specified later -- see
[Appendix A](#setting-values-for-templated-variables)

<figure>
<img src="media/image6.png" style="width:5.99622in;height:3.02117in"
alt="A screenshot of a computer Description automatically generated" />
<figcaption><p>Figure 6. Example of a manifest yaml file with a variable
template.</p></figcaption>
</figure>

### 

###  ClusterForge cast step

The "cast" step will take the prepared manifests from folder
cluster-forge/working/ and produce the stack definition files under
folder

cluster-forge/stacks/\<stack-name\>/.

To run this step, enter the following command in the ClusterForge root
directory cluster-forge/:

```
go run . cast
```

By default, this stack image will be available for 12 hours in a
[ttl.sh](https://ttl.sh/) image registry as shown in Figure 7:

<figure>
<img src="media/image7.png" style="width:4.97461in;height:2.34274in" />
<figcaption><p>Figure 7. Cast step producing an ephemeral
stack</p></figcaption>
</figure>

To publish the stack image to the registry of your choice, include the
flag PUBLISH_IMAGE=true as:

```
PUBLISH_IMAGE=true go run . cast
```

As shown in Figure 8, the terminal will prompt for giving a name for the
composition package to be made, i.e. "cast". Please type the name of
your choice and press enter to continue.

> ![A black background with purple text Description automatically
> generated](media/image8.png){width="4.625239501312336in"
> height="0.9167093175853018in"}

Figure 8. View of the prompt to enter a name for a stack to "cast".

If using PUBLISH_IMAGE=true then you will additionally be prompted to
input the container registry and package name as in Figure 9:

<figure>
<img src="media/image9.png" style="width:6.33467in;height:1.4808in" />
<figcaption><p>Figure 9: Prompt for private repository</p></figcaption>
</figure>

Input a valid URL domain and tag. This will produce an output similar to
that of Figure 7, but with the stack name and stack image.

If you omit this step, the image will be published to a temporary,
ephemeral repository in ttl.sh\
\
Do not put any actual secret or confidential into a temporary, ephemeral
package on ttl.sh!

![](media/image10.png){width="4.670259186351706in"
height="2.2133792650918633in"}

Figure 10: Output after publishing to private repository. This should be
redone

After this, a menu like the one in the "smelt" step is shown to select
the services to be included in this stack. Make the selection by typing
'x' and finally click 'enter'.

The cast step will also produce a placeholder file
cluster-forge/templates/ stack.yaml for entering values for the
templated variables in the next step.

### Setting values for templated variables

The values for the templated variables must be added into the file
cluster-forge/

templates/stack.yaml which was produced by the previous "cast" step. In
Figure 11, an example of such a file is shown. ![A grey screen with
brown text Description automatically
generated](media/image11.png){width="5.866669947506562in"
height="1.4629090113735783in"}

**Figure** 11**.** *Example of XForge manifest to define values for
templated variables.*

In the example of Figure 11, in the spec section there are two key-value
pairs defined for templated variables; namely domain:demo.silogen.ai and
storageClass: directpv-min-io. Please add the name of each templated
variable and corresponding values for each of them into the file
[cluster-forge](https://github.com/silogen/cluster-forge/tree/add-ray-examples)/templates/stack.yaml
in an analogous way as key-value pairs in the spec section of the
example file shown in Figure 11.

### Ephemeral Stack with ClusterForge Forge step

As described in the chapter introduction, this section shows how to run
ClusterForge and store the resulting image in the ephemeral image
registry. Simply run the following command in the ClusterForge root
directory cluster-forge/ to run both smelt and cast

```
go run . forge
```

This will prompt the component selection as shown in Figure 5, and these
components are automatically then casted into a stack with the name
ephemeral-stack and the temporary stack image as previously shown in
Figure 7:

### Deploying the Stack

The process of deploying the stack is the same as described
[above](#installation-from-clusterforge-release)

## **Appendix B**. Using Kaiwo

[]{#_Appendix_C._LLM .anchor}Chapter 5 introduced kaiwo and how to
install Kaiwo CLI to be able to run the example workloads. This section
provides more details and general usage guidelines for Kaiwo.

### Usage

Run kaiwo \--help for an overview of currently available commands.

In case your certificate trust store gives \"untrusted\" certificate
errors, you can use insecure-skip-tls-verify: true under cluster and
\--insecure-skip-tls-verify in kubelogin get-token as a temporary
workaround. As usual, we don\'t recommend this in production.

### Deploying with Kaiwo

Kaiwo allows you to both submit jobs and serve deployments. It\'s
important to note that kaiwo serve does not use Kueue or any other form
of job queueing. The assumption is that immediate serving of models is
required when using serve. We encourage users to use separate clusters
for submit and serve. Currently, the following types are supported:

-   Standard Kubernetes jobs batch/v1 Job via kaiwo submit

-   Ray jobs ray.io/v1 RayJob via kaiwo submit \--ray

-   Ray services ray.io/v1 RayService via kaiwo serve \--ray

-   Standard Kubernetes deployments apps/v1 Deployment via kaiwo serve

The workloads directory includes examples with code for different types
workloads that you can create.

RayServices are intended for online inference. They bypass job queues.
We recommend running them in a separate cluster as services are
constantly running and therefore reserve compute resources 24/7. RayJobs
and RayServices require using the -p/\--path option. Kaiwo will look for
entrypoint or serveconfig files in path which are required for RayJobs
and RayServices, respectively.

Run kaiwo submit \--help and kaiwo serve \--help for an overview of
available options. To get started with a workload, first make sure that
your code (e.g. finetuning script) works with the number of GPUs that
you request via kaiwo submit/serve. For example, the following command
will run the code found in path as a RayJob on 16 GPUs.

```
kaiwo submit -p path/to/workload/directory -g 16 \--ray
```

By default, this will run in kaiwo namespace unless another namespace is
provided with -n or \--namespace option. If the provided namespace
doesn\'t exist, use \--create-namespace flag.

You can also run a workload by just passing \--image or -i flag.

```
kaiwo submit -i my-registry/my_image -g 8
```

Or, you may want to mount code from a github repo at runtime and only
modify the entrypoint for the running container. In such a case and when
submitting a standard Kubernetes Job, add entrypoint file to \--path
directory and submit your workload like so

```
kaiwo submit -i my-registry/my_image -p path_to_entrypoint_directory -g 8
```

One important note about GPU requests: it is up to the user to ensure
that the code can run on the requested number of GPUs. If the code is
not written to run on the requested number of GPUs, the job will fail.
Note that some parallelized code may only work on a specific number of
GPUs such as 1, 2, 4, 8, 16, 32 but not 6, 10, 12 etc. If you are
unsure, start with a single GPU and scale up as needed. For example, the
total number of attention heads must be divisible by tensor parallel
size.

When passing custom images, please be mindful that kaiwo mounts local
files to /workload for all jobs and to /workload/app for services
(RayService, Deployment) to adhere to RayService semantics

#### Note about environment variables

Kaiwo cannot assume how secret management has been set up on your
cluster (permissions to create/get secrets, backend for ExternalSecrets,
etc.). Therefore, Kaiwo does not create secrets for you. If your
workload requires secrets, such as for storage or access, you must
create them yourself. You can create secrets in the namespace where you
are running your workload. If you are using ExternalSecrets, make sure
that the ExternalSecrets are created in the same namespace where you are
running your workload.

To pass environment variables (from secrets or otherwise) into your
workload, you can add env file to the \--path directory. The file format
follows YAML syntax and looks something like this:

```
  envVars:\
  - name: MY_VAR\
  value: \"my_value\"\
  - fromSecret:\
  name: \"AWS_ACCESS_KEY_ID\"\
  secret: \"gcs-credentials\"\
  key: \"access_key\"\
  - fromSecret:\
  name: \"AWS_SECRET_ACCESS_KEY\"\
  secret: \"gcs-credentials\"\
  key: \"secret_key\"\
  - fromSecret:\
  name: \"HF_TOKEN\"\
  secret: \"hf-token\"\
  key: \"hf-token\"\
  - mountSecret:\
  name: \"GOOGLE_APPLICATION_CREDENTIALS\"\
  secret: \"gcs-credentials\"\
  key: \"gcs-credentials-json\"\
  path: \"/etc/gcp/credentials.json\"
```

#### Enabling auto-completion for Kaiwo

The instructions for setting up auto-completion differ slightly by type
of terminal. See help with kaiwo completion \--help

For bash, you can run the following

``` sudo apt update && sudo apt install bash-completion && \\\
  kaiwo completion bash \| sudo tee /etc/bash_completion.d/kaiwo \>
  /dev/null
```

You have to restart your terminal for auto-completion to take effect.

### Workload Templates

Kaiwo manages Kubernetes workloads through templates. These templates
are YAML files that use go template syntax. If you do not provide a
template when submitting or serving a workload by using the \--template
flag, a default template is used. The context available for the template
is defined by the [WorkloadTemplateConfig
struct](https://github.com/silogen/kaiwo/blob/main/pkg/workloads/config.go),
and you can refer to the default templates for
[Ray](https://github.com/silogen/kaiwo/blob/main/pkg/workloads/ray) and
[Kueue](https://github.com/silogen/kaiwo/blob/main/pkg/workloads/jobs).

If you want to provide custom configuration for the templates, you can
do so via the -c / \--custom-config flag, which should point to a YAML
file. The contents of this file will then be available under the .Custom
key in the templates. For example, if you provide a YAML file with the
following structure

  -----------------------------------------------------------------------
  parent:\
  child: \"value\"
  -----------------------------------------------------------------------

  -----------------------------------------------------------------------

You can access this in the template via

{{ .Custom.parent.child }}

## **Appendix C**. LLM Tokens 

To run certain AI workloads, such as **Llama 3.1** or other models
provided by Hugging Face, you need to have proper authentication to
access these resources. Hugging Face, a popular platform for AI models
and tools, requires an **API token** for accessing and downloading
models.

### What is a Hugging Face Token?

A Hugging Face token is like a digital key that allows your systems or
applications to securely communicate with Hugging Face and access their
models, datasets, or APIs. Without this token, you won\'t be able to use
many of their resources in your workflows.

### Why Do You Need to Install It as a Secret?

Tokens contain sensitive information. To keep them secure and prevent
unauthorized access, they should not be stored in plain text in your
code or configuration files. Instead, they are stored as **secrets**---a
secure way to manage sensitive data.

### How to Get a Hugging Face Token

1.  Create or log in to your Hugging Face account:
    [https://huggingface.co](https://huggingface.co/).

2.  Navigate to your account settings.

3.  Under **Access Tokens**, generate a new token.

4.  Copy the token (keep it safe; don\'t share it).

### Where to Install the Token

The token needs to be installed as a secret in your environment. Here
are examples of how to do this in common platforms:

On Kubernetes

Save the token in an environment variable in your terminal:

```
kubectl create secret generic hf-token --from-literal=hf-token=my_super_secret_token -n my_namespace
```
