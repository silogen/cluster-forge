# Setup scripts

`setup.sh` copies the semantic-router blueprint into the cluster-values repository. The blueprint README is the install guide. This page is what the script changes.

`setup-dashboard-admin.sh` enables the OpenBao dashboard admin. Run it from the same directory, after `setup.sh`. The section [Dashboard admin](#dashboard-admin) lists what that script changes.

The script reads the cluster domain from kubectl. It writes that domain into the dashboard host name and the router host name. It also writes the smoke-test model names. The script commits those files and pushes the commit. After the push, the script creates Secret `semantic-router-client-keys` on the cluster when that Secret is absent.

## Blueprint path

The script finds the blueprint from the path of `setup.sh`. The blueprint is the parent directory of `scripts/`. You do not set the blueprint path.

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

cluster-bloom writes the key `DOMAIN`. When that key is empty, the script reads the key `domain`. The manual install guide writes that key.

The script changes the domain to lowercase. The domain must be an RFC 1123 host name, the format that an HTTPRoute hostname accepts. The script stops when the domain has a different format.

The dashboard host name is `sr-dashboard.<domain>`. The router host name is `sr.<domain>`.

## Files

| Source under the blueprint | Destination in cluster-values |
|---|---|
| `extraApps.yaml` | `extra-apps-values.yaml`, key `extraApps.semantic-router` only |
| `values.yaml` | `extra-apps/semantic-router/values.yaml` |
| `chart/` | `extra-apps/semantic-router/chart/` |
| `manifests/dashboard-admin-externalsecret.yaml` | Not copied by `setup.sh`. `setup-dashboard-admin.sh` copies it to `extra-apps/semantic-router/chart/templates/`. A later run of `setup.sh` keeps that copy. |
| `manifests/gateway-routing-direct-envoy.yaml` | Not copied. Annotated example for `routing.mode: envoy`. |

A later run replaces `chart/` and deletes `extra-apps/semantic-router/manifests` when that directory is present. The old install kept gateway files in `manifests/`. The chart is the source Argo CD syncs.

## Replacements

The script replaces each match in `extra-apps/semantic-router/values.yaml`. A match in a comment changes too. A different TODO name stays in the file.

A later run copies `values.yaml` from the blueprint again and writes the smoke-test names again. Put real model ids and Service addresses into `models.small`, `models.medium`, and `models.large` after the last run. The blueprint README names the fields.

| Text in the blueprint | Text after the script |
|---|---|
| `sr-dashboard.mycluster.example.com` | `sr-dashboard.<domain>` |
| `sr.mycluster.example.com` | `sr.<domain>` |
| `TODO-small-model` | `smoke-test-small` |
| `TODO-medium-model` | `smoke-test-medium` |
| `TODO-large-model` | `smoke-test-large` |
| `TODO-your-vllm-service.TODO-your-vllm-namespace.svc.cluster.local:8000` | `test-vllm.semantic-router.svc.cluster.local:8000` |

The three ids differ so the gateway chart can create one backend per model. The three endpoints share the smoke-test Service.

## Git commands

The script runs these commands in the current repository:

```bash
git add extra-apps-values.yaml extra-apps/semantic-router
git commit -m "feat: Add semantic-router extra app"
git push
```

A second run with the same files skips the commit. Each run pushes, so a second run also pushes a commit that an earlier run did not push.

### Push credentials

When `GITEA_USERNAME` and `GITEA_PASSWORD` are both set, the push uses them and git does not prompt. Otherwise git prompts for the Gitea user and password.

```bash
export GITEA_USERNAME=$(kubectl -n cf-gitea get secret gitea-admin-credentials -o jsonpath='{.data.username}' | base64 -d)
export GITEA_PASSWORD=$(kubectl -n cf-gitea get secret gitea-admin-credentials -o jsonpath='{.data.password}' | base64 -d)
```

The scripts pass the values to git through a credential helper that reads the environment. The values do not appear on the command line, and the scripts do not write them to the repository or to git config. The variables apply only to the `git push` in each script. A clone or push outside the scripts still prompts. Only an HTTP remote uses these values. An SSH remote ignores them.

`setup-dashboard-admin.sh` uses the same variables.

## API key

The script creates namespace `semantic-router` when that namespace is absent. It then creates Secret `semantic-router-client-keys` when that Secret is absent. The Secret data key is `smoke-client`. The gateway chart's `SecurityPolicy` reads that key.

The script prints the key once:

```text
smoke-client API key: <key>
```

Send that value as `Authorization: Bearer <key>`. The script does not write the key into the repository. A later run does not replace an existing Secret.

## Dashboard admin

`setup-dashboard-admin.sh` is dashboard way 2 in the blueprint README. Way 2 uses OpenBao on a bloomed cluster. Run the script from the root of the cluster-values repository, after `setup.sh`. The gateway chart directory must already be present. The script stops when that directory is absent.

```bash
/path/to/cluster-forge/root-extras/blueprints/semantic-router/scripts/setup-dashboard-admin.sh
```

The script does not call kubectl. Git uses the remote of the current repository for the push. The script needs mikefarah `yq`.

| Source under the blueprint | Destination in cluster-values |
|---|---|
| `manifests/dashboard-admin-externalsecret.yaml` | `extra-apps/semantic-router/chart/templates/dashboard-admin-externalsecret.yaml` |

The script also edits `extra-apps/semantic-router/values.yaml`. The blueprint ships `dashboard.jwtSecret` and `dashboard.extraEnv` as comments. The script removes the comment marker on that block. It checks that both keys point at Secret `semantic-router-dashboard-admin`. A second run leaves an already active block as it is.

The script runs these commands:

```bash
git add extra-apps/semantic-router/chart/templates/dashboard-admin-externalsecret.yaml extra-apps/semantic-router/values.yaml
git commit -m "feat: Enable semantic-router dashboard admin"
git push
```

A second run with the same files skips the commit. Each run pushes.

A later run of `setup.sh` copies `values.yaml` from the blueprint again. `jwtSecret` and `extraEnv` are comments again. Run `setup-dashboard-admin.sh` after that run. `setup.sh` keeps the ExternalSecret file.

After the Application is Synced, sign in at `https://sr-dashboard.<domain>`. The email is `admin@<domain>`. The display name is `admin`. Read the password:

```bash
kubectl -n semantic-router get secret semantic-router-dashboard-admin \
    -o jsonpath='{.data.password}' | base64 -d; echo
```
