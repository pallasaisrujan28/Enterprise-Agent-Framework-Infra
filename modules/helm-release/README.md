# `modules/helm-release`

One Helm release, with the defaults this repository learned the hard way.

```hcl
module "release" {
  source = "../helm-release"

  name      = "neo4j"
  namespace = "memory"

  repository    = "https://helm.neo4j.com/neo4j"
  chart         = "neo4j"
  chart_version = "5.26.30"      # required, no default

  values = {                      # one object, not a list of `set` blocks
    neo4j = { edition = "community" }
    volumes = { data = { mode = "dynamic" } }
  }

  wait            = true
  timeout_seconds = 900
  atomic          = true
}
```

## Why wrap a single resource

Three settings decide whether a failed release is *visible*, and all three defaulted the wrong
way in the configuration this replaces: `wait = false`, no bounded timeout, and no `atomic`. A
release could be created with a failed status while the apply reported success — which is how
`helm list` came to disagree with what was actually running.

Centralising them means the safe combination is what you get by saying nothing, and a deviation
is a visible argument at the call site rather than an omission.

| Setting | Default here | Why |
|---|---|---|
| `wait` | `true` | Off, a failed release reports as a successful apply |
| `timeout_seconds` | `600` | Bounded. An unbounded wait is a hung pipeline with no diagnostic |
| `atomic` | `true` | A failed release does not stay installed |
| `create_namespace` | `false` | Namespaces belong to the cluster-addons layer |

`wait = false` was a reasonable instinct with a bad consequence: it stopped Helm blocking an
apply that shared one state file with everything else, and moved the health check from inside
the apply to nowhere. The fix for a slow apply is a layer boundary, which now exists.

### `atomic` does not delete data

A StatefulSet's PersistentVolumeClaims come from a `volumeClaimTemplate`, and Kubernetes
deliberately does not garbage-collect them when the StatefulSet goes away. An atomic rollback
leaves the volume intact.

### `create_namespace = false` is a boundary, not a nicety

A namespace created by Helm would have no default-deny NetworkPolicy, no quota and no
LimitRange — and would look identical in `kubectl get ns`.

## Values go in as YAML, never through `set`

```hcl
values = { replicas = 3, enabled = true }   # renders as `"replicas": 3`
```

Three reasons, and the third is the one that would eventually force a rewrite:

1. **`set` stringifies everything.** `replicas = 1` arrives as `"1"`, and a chart doing
   arithmetic on it fails inside a template rather than at plan time.
2. **Nested and list values need `a.b[0].c` paths**, whose escaping rules collide with keys
   that contain dots — which is most Kubernetes annotations and every Neo4j config key.
3. **`set` is the exact surface the provider changed between v2 and v3.** Passing values as one
   YAML document means this module has no opinion on that change.

Note that `yamlencode` quotes keys, so the document reads `"replicas": 3`. That is the same
YAML and Helm parses it identically; only the value side of the colon carries type information,
which is what the tests assert on.

## Provider version floor is `>= 3.0.0`, deliberately

The v3 provider moved from Plugin SDKv2 to the Plugin Framework, turning `set`,
`set_sensitive`, `postrender` **and the provider's own `kubernetes` block** from nested blocks
into typed attributes. A module written against v2 syntax does not parse under v3, so a floor
admitting both majors would guarantee nothing.

In a root module the provider is therefore configured with `=` and braces:

```hcl
provider "helm" {
  kubernetes = {            # attribute in v3, block in v2
    host = ...
    exec = { command = "aws", args = [...] }
  }
}
```

Written as blocks it fails with an "unsupported block type" error that names the block but not
the provider version that changed it.

## `chart_version` is required

An unpinned chart is an unpinned dependency: the repository's `index.yaml` is mutable, so
"latest" resolves to whatever was published most recently, and two applies of identical
Terraform can install different software. Same class of defect as an image tag of `latest`.

A *range* is no better. Helm resolves it at install time, not plan time, so the plan a reviewer
approved would not name the version that gets installed.

## Inputs

| Name | Type | Default |
|---|---|---|
| `name` | string | — |
| `namespace` | string | — |
| `repository` | string | `null` (for local paths and `oci://`) |
| `chart` | string | — |
| `chart_version` | string | — (required) |
| `values` | any | `{}` |
| `wait` | bool | `true` |
| `timeout_seconds` | number | `600` (1–3600) |
| `atomic` | bool | `true` |
| `create_namespace` | bool | `false` |
| `recreate_pods` | bool | `false` |

`atomic` requires `wait` — a rollback decision cannot be made without waiting to see whether
the release became ready. Enforced by a precondition.

## Outputs

`name`, `namespace`, `chart_version`, `status`, `inventory`, and `rendered_values` (sensitive).

`rendered_values` exists so a **calling module's tests can assert on what the chart actually
receives**, rather than on the caller's description of it. Without it the only checkable thing
is an inventory output — a string a human wrote — and the two can drift apart silently. That is
not hypothetical: it is how a `ClusterIP` claim survived a change to `LoadBalancer` in
`modules/neo4j` until mutation testing caught it.

## Tests

9 tests, `command = plan`, mocked provider.
