# infisical-secret

Syncs folders from [Infisical](https://infisical.com/) into Kubernetes
Secrets. Each entry in `secrets` renders one `InfisicalSecret`
(`secrets.infisical.com/v1alpha1`), which the
[Infisical operator](https://infisical.com/docs/integrations/platforms/kubernetes/overview)
turns into a managed Secret.

The [philomena](../philomena/) chart includes it as an optional dependency
aliased to `infisical`, gated on `infisical.enabled` (off by default). It can
also be installed on its own.

## Prerequisites

- The Infisical operator installed in the cluster, in a version whose
  `InfisicalSecret` has `managedKubeSecretReferences` (the successor of the
  deprecated `managedSecretReference`).
- A universal-auth machine identity with access to the project. Its
  credentials go into the Secret named by `credentialsRef` (default
  `universal-auth-credentials` in the release namespace):

  ```bash
  kubectl create secret generic universal-auth-credentials \
    --from-literal=clientId=<client id> \
    --from-literal=clientSecret=<client secret>
  ```

## Values

| Key | Description | Default |
| :-- | :---------- | :------ |
| `hostAPI` | Infisical API URL (Infisical Cloud EU: `https://eu.infisical.com/api`; self-hosted: your instance's `/api`) | `https://app.infisical.com/api` |
| `projectSlug` | Infisical project slug (required when any secret is enabled) | `""` |
| `envSlug` | Infisical environment slug | `prod` |
| `credentialsRef.secretName` | Universal-auth credentials Secret | `universal-auth-credentials` |
| `credentialsRef.secretNamespace` | Namespace of that Secret (empty = release namespace) | `""` |
| `resyncInterval` | Seconds between two syncs (unset = the operator's default) | unset |
| `secrets` | Map of secrets to sync, keyed by a short lowercase name | `{}` |

Each `secrets.<key>` entry accepts:

| Field | Description | Default |
| :---- | :---------- | :------ |
| `enabled` | Render this entry | `true` |
| `secretsPath` | Infisical folder to sync | `/` |
| `recursive` | Include subfolders | `false` |
| `projectSlug` / `envSlug` | Override the top-level values | top-level values |
| `secretName` | Managed Secret name | `<release>-<key>` |
| `secretNamespace` | Namespace of the managed Secret | release namespace |
| `secretType` | Secret type, e.g. `kubernetes.io/basic-auth` | `Opaque` |
| `creationPolicy` | `Owner` (the Secret is deleted with the InfisicalSecret) or `Orphan` | `Owner` |

The `InfisicalSecret` itself is always named `<release>-<key>`.

## Example

```yaml
projectSlug: myapp-x1-y2
secrets:
  env:
    secretsPath: /
    recursive: true
  database:
    secretsPath: /database
    secretName: myapp-postgres-auth
    secretType: kubernetes.io/basic-auth
```

This renders `<release>-env` (Opaque, synced from `/` recursively) and
`myapp-postgres-auth` (basic-auth, synced from `/database`).

## Use as a subchart

```yaml
# Chart.yaml
dependencies:
  - name: infisical-secret
    alias: infisical
    version: "1.0.0"
    repository: "https://charts.philomena.dev"
    condition: infisical.enabled
```

Subchart templates are not available to the parent while the subchart is
disabled, so a parent chart works out the Secret name itself: its
existing-secret value when set, otherwise `secrets.<key>.secretName`,
otherwise `<release>-<key>`. Keep that logic in step with this chart if the
naming changes.
