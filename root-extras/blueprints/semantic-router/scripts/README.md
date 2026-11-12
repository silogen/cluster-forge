# Setup script

`setup.sh` copies the semantic-router blueprint into the cluster-values repository. The blueprint README is the install guide. This page is what the script changes.

The script reads the cluster domain from kubectl. It writes that domain into the dashboard host name and the router host name. It also writes the smoke-test model names. The script commits those files and pushes the commit. After the push, the script creates Secret `semantic-router-client-keys` on the cluster when that Secret is absent.

## Blueprint path

The script sets `SRC` from the path of `setup.sh`. `SRC` is the parent directory of `scripts/`. This is the blueprint directory. You do not set `SRC`.

Start `setup.sh` by any path. The blueprint path stays the same.

## Destination

The script writes files in the current directory. Run the script from the root of the cluster-values repository. That directory is a git repository. It is not the cluster-forge repository.

The script merges the `semantic-router` key into `extra-apps-values.yaml`. When that key is already present, the script replaces it. Other keys in `extraApps` stay. When the file is missing or empty, the script creates `extraApps: {}` and then adds the key. `extraApps` must be a map, or absent. The script stops when `extraApps` is another type.

The script needs mikefarah `yq`. It stops when that `yq` is not on `PATH`.

## Procedure

1. Point kubectl at the cluster. Set `KUBECONFIG`, or use the current context.
2. Clone the cluster-values repository.
3. Change to the root of that repository.
4. Start the script:

```bash
/path/to/cluster-forge/root-extras/blueprints/semantic-router/scripts/setup.sh
```

The script prints the blueprint path, the destination path, and the cluster domain. Git uses the remote of the current repository for the push.

The script reads the domain with this command:

```bash
kubectl get configmap cluster-domain --namespace default --output jsonpath='{.data.DOMAIN}'
```

The dashboard host name is `sr-dashboard.<domain>`. The router host name is `sr.<domain>`.

## Files

| Source under the blueprint | Destination in cluster-values |
|---|---|
| `extraApps.yaml` | `extra-apps-values.yaml`, key `extraApps.semantic-router` only |
| `values.yaml` | `extra-apps/semantic-router/values.yaml` |
| `manifests/gateway-routing.yaml` | `extra-apps/semantic-router/manifests/gateway-routing.yaml` |
| `manifests/dashboard-admin-externalsecret.yaml` | `extra-apps/semantic-router/manifests/dashboard-admin-externalsecret.yaml` |
| `manifests/aigw-extras/sr-gateway.yaml` | `extra-apps/semantic-router/manifests/sr-gateway.yaml` |
| `manifests/aigw-extras/sr-gateway-config.yaml` | `extra-apps/semantic-router/manifests/sr-gateway-config.yaml` |
| `manifests/aigw-extras/sr-gateway-proxy-config.yaml` | `extra-apps/semantic-router/manifests/sr-gateway-proxy-config.yaml` |
| `manifests/aigw-extras/sr-gateway-service.yaml` | `extra-apps/semantic-router/manifests/sr-gateway-service.yaml` |
| `manifests/aigw-extras/sr-gateway-extproc.yaml` | `extra-apps/semantic-router/manifests/sr-gateway-extproc.yaml` |

## Replacements

The script replaces each match in the destination file. A match in a comment changes too. A different TODO name stays in the file.

A later run copies `values.yaml` and `gateway-routing.yaml` from the blueprint again. That run writes the smoke-test model names again. Put real Service addresses and model IDs into those files after the last run of this script. The blueprint README names the fields.

In `extra-apps/semantic-router/values.yaml`:

| Text in the blueprint | Text after the script |
|---|---|
| `sr-dashboard.mycluster.example.com` | `sr-dashboard.<domain>` |
| `TODO-your-vllm-service:8000` | `test-vllm.semantic-router.svc:8000` |
| `TODO-your-model` | `smoke-test-model` |

In `extra-apps/semantic-router/manifests/gateway-routing.yaml`:

| Text in the blueprint | Text after the script |
|---|---|
| `sr.mycluster.example.com` | `sr.<domain>` |
| `TODO-your-vllm-service.TODO-your-vllm-namespace.svc.cluster.local` | `test-vllm.semantic-router.svc.cluster.local` |
| `TODO-your-model-backend` | `smoke-test-backend` |
| `TODO-your-backend-model` | `smoke-test-model` |
| `TODO-your-model` | `smoke-test-model` |
| `TODO-your-client-name` | `smoke-client` |

## Git commands

The script runs these commands in the current repository:

```bash
git add extra-apps-values.yaml extra-apps/semantic-router
git commit -m "feat: Add semantic-router extra app"
git push
```

A second run with the same files skips the commit and the push.

## API key

The script creates namespace `semantic-router` when that namespace is absent. It then creates Secret `semantic-router-client-keys` when that Secret is absent. The Secret data key is `smoke-client`. That name matches the client name written into `gateway-routing.yaml`.

The script prints the key once:

```text
smoke-client API key: <key>
```

Send that value as `Authorization: Bearer <key>`. The script does not write the key into the repository. A later run does not replace an existing Secret.
