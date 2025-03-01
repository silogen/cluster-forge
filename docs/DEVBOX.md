<!-- gen-readme start - generated by https://github.com/jetify-com/devbox/ -->
## Getting Started
This project uses [devbox](https://github.com/jetify-com/devbox) to manage its development environment.

Install devbox:
```sh
curl -fsSL https://get.jetpack.io/devbox | bash
```

Start the devbox shell:
```sh 
devbox shell
```

Run a script in the devbox environment:
```sh
devbox run <script>
```
## Scripts
Scripts are custom commands that can be run using this project's environment. This project has the following scripts:

* [clean](#devbox-run-clean)
* [resetKind](#devbox-run-resetKind)

## Environment

```sh
KREW_ROOT="${DEVBOX_PROJECT_ROOT}/.krew"
```

## Shell Init Hook
The Shell Init Hook is a script that runs whenever the devbox environment is instantiated. It runs 
on `devbox shell` and on `devbox run`.
```sh
source $DEVBOX_PROJECT_ROOT/.zshadd
```

## Packages

* [go@1.23](https://www.nixhub.io/packages/go)
* [ansible@2.18.1](https://www.nixhub.io/packages/ansible)
* [kubectl@1.32.1](https://www.nixhub.io/packages/kubectl)
* [kubernetes-helm@3.17.0](https://www.nixhub.io/packages/kubernetes-helm)
* [krew@0.4.4](https://www.nixhub.io/packages/krew)
* [kubecolor@0.5.0](https://www.nixhub.io/packages/kubecolor)
* [kubelogin-oidc@1.31.1](https://www.nixhub.io/packages/kubelogin-oidc)
* [k9s@0.32.7](https://www.nixhub.io/packages/k9s)

## Script Details

### devbox run clean
```sh
rm -rf working/*
rm -rf working/.git
rm -rf output/*
rm -rf stacks/latest
rm -rf Library
rm -rf logs/*.log
```
&ensp;

### devbox run resetKind
```sh
kind delete cluster -n forgetest
kind create cluster -n forgetest
kind export kubeconfig -n forgetest --kubeconfig forgetest.yaml
```
&ensp;



<!-- gen-readme end -->
