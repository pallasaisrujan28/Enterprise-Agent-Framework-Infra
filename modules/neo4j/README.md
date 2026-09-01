# `modules/neo4j`

Neo4j standalone: authenticated, on a named StorageClass, reachable only by named clients.

```hcl
module "neo4j" {
  source = "../../../modules/neo4j"

  name      = "neo4j"
  namespace = "memory"          # must already exist — see below

  chart_version      = "5.26.30"
  storage_class_name = "gp3"
  storage_size       = "10Gi"

  allowed_client_namespaces = ["eaf"]
  allow_same_namespace      = true
  network_policy_enforced   = true   # an assertion, not a switch
}
```

## Three chart defaults this module overrides, and why each matters

The upstream chart is written for a generic Kubernetes cluster. Three of its defaults are
actively wrong on EKS.

### `services.neo4j.spec.type` defaults to `LoadBalancer`

The single most important override. On EKS that provisions an **internet-facing Network Load
Balancer in front of the graph database**. Two separate problems:

- **Exposure.** Bolt on 7687 reachable from the internet. Memory is the store that accumulates
  whatever the agent has been told, so it is the least appropriate thing in the platform to
  publish.
- **A leak.** The NLB is created by an in-cluster controller, so no Terraform state knows it
  exists. About **$19.32/month** in `eu-west-2`, and its ENIs hold the subnets, so the VPC
  destroy later fails with `DependencyViolation`.

Overridden to `ClusterIP`. The browser is reached with `kubectl port-forward`, which does not
traverse a Service and so needs nothing opened.

The override is verified by a test that reads **the YAML actually sent to Helm**, not the
module's own description of itself. An earlier version of that test checked only the inventory
output, and mutation testing showed that flipping the chart value to `LoadBalancer` failed
nothing — the inventory and the reality were two independent literals. They now share one
`local`, and the test asserts on `module.release.rendered_values`.

### The data volume defaults to 100Gi

About $9.28/month for a graph that starts empty. Default here is `10Gi`, and gp3 allows
expansion in place, so growing it later is not a recreate.

### Authentication

The configuration this replaces set `dbms.security.auth_enabled: false`, which made reaching
the network sufficient to read and write everything.

**Authentication is now on by construction, not by a flag set correctly.** Setting
`passwordFromSecret` while also disabling auth is a hard template failure in the chart, so
there is no combination of this module's inputs that produces an unauthenticated database.
That is a stronger guarantee than remembering not to disable it.

## The credential, and two ways to get it silently wrong

The module generates a password and owns the Secret. Both details of its format are
load-bearing, and both fail with a message that points somewhere else.

| Requirement | Failure if wrong |
|---|---|
| Key must be `NEO4J_AUTH` | `Secret ... must contain key NEO4J_AUTH` |
| Value must be `neo4j/<password>`, not a bare password | `Password in secret ... must start with the characters 'neo4j/'` — reads like a password policy |
| Password must contain no `/` | **None.** The release installs and authentication then fails |

That third row is the dangerous one. The chart recovers the password with
`kubectl get secret ... | cut -d '/' -f2`, so a slash truncates it silently. The chart's own
validation regex (`^neo4j\/\w*`) uses a *find* rather than a full match, so a password with
punctuation passes validation and then breaks at the `cut`. The module generates alphanumeric
only — 32 characters, about 190 bits, which is more entropy than a symbol set would buy.

### Why the module owns the Secret at all

`neo4j.passwordFromSecret` was added upstream specifically to fix a data race with Terraform
and Argo. Given a plain `neo4j.password`, the chart creates the Secret itself, and on a second
apply its `lookup` of its own Secret races with the release that owns it. Owning the Secret
here removes the race and keeps the generated value out of the rendered values a plan prints.

## Networking

The namespace already denies all ingress (`modules/k8s-namespace`), so this module's policy is
what **allows** bolt through. It opens 7687 only — 7474 is the HTTP browser and is not
something a workload should reach.

Client namespaces are selected by the `eaf.io/namespace` label, which `modules/k8s-namespace`
sets for exactly this purpose.

`network_policy_enforced` is an **assertion**, mirroring `modules/k8s-namespace`. Nothing here
turns enforcement on; that is the `vpc-cni` add-on in the platform layer. It matters more for
an allow policy than for a deny: if enforcement is off, this policy is inert *and so is the
deny it was written against*, so the database is open while every object looks correct. When
the assertion is false the module creates no policy and says so in the inventory.

With no client namespaces and `allow_same_namespace = false`, nothing can reach the database.
That is a valid state before a consumer exists, reported as
`inventory.access.reachable_by_anything = false` rather than as a failure.

## Storage, and what a teardown does

`dynamic` volume mode names the StorageClass rather than relying on whichever class is marked
default. The `gp3` class uses `WaitForFirstConsumer`, which is what makes a zonal volume safe:
the volume is created in the zone the pod was scheduled into, rather than being created first
and then constraining the scheduler to a zone that may have no capacity.

**Destroying this module destroys the graph.** `inventory.storage.data_is_destroyed_with_this_module`
states it rather than implying it. Note that this is only true when the destroy happens in
order — `scripts/teardown_guard.py` refuses to destroy the platform layer while this one still
holds resources, because a cluster destroyed with the PVC still present *leaks* the volume
instead of deleting it. See `learnings/007`.

## Version

Default `5.26.30`: the newest patch of the 5.26 **LTS** line, supported until June 2028, and
the floor [Graphiti documents](https://help.getzep.com/graphiti/configuration/neo-4-j-configuration)
as its minimum. The chart has since moved to calendar versioning (`2026.x`), but nothing
documents Graphiti against that generation, and the graph's contents are expensive to rebuild.

`edition: community` — no licence required, single-database, non-clustered, which is what a
standalone instance is anyway.

## Inputs

| Name | Type | Default | Notes |
|---|---|---|---|
| `name` | string | `neo4j` | Every chart object derives its name from this |
| `namespace` | string | — | Must already exist |
| `chart_version` | string | `5.26.30` | Pinned exactly |
| `storage_class_name` | string | `gp3` | Named, not inherited |
| `storage_size` | string | `10Gi` | Chart default is 100Gi |
| `cpu_request` | string | `500m` | Chart default 1000m is half an m6i.large |
| `memory_request` | string | `2Gi` | Neo4j sizes heap and page cache from this |
| `allowed_client_namespaces` | list(string) | `[]` | Selected by `eaf.io/namespace` |
| `allow_same_namespace` | bool | `true` | Graphiti lands here |
| `network_policy_enforced` | bool | `true` | An assertion |
| `password_length` | number | `32` | Alphanumeric, ≥ 16 |
| `apoc_enabled` | bool | `true` | Triggers and UUID, both of which Graphiti calls |
| `labels` | map(string) | `{}` | Merged first; module labels win |

## Outputs

`bolt_uri`, `http_uri`, `service_host`, `username`, `password_secret_name`,
`password_secret_key`, `password` (sensitive), `inventory`.

Prefer `password_secret_name` over `password`. A password threaded through an output lands in
the consuming layer's state as well as this one, doubling the places it must be protected.

`bolt_uri` uses `bolt://`, not `neo4j://`. The latter requests a routing table, and a
single-instance Community deployment answers with an error about routing being unavailable
rather than a connection.

## Tests

15 tests, `command = plan`, mocked providers, no cluster and no credentials.

Several pin the **upstream chart's** contract rather than this module's logic — the
`NEO4J_AUTH` key, the `neo4j/` prefix, ClusterIP over LoadBalancer. Each was read out of the
chart's templates, and each fails in a way that names something other than the real cause.

Verified by mutation. Six injected defects, each caught: dropping the `neo4j/` prefix, renaming
the Secret key, allowing special characters in the password, reverting to `LoadBalancer`,
opening 7474 instead of 7687, and creating the allow policy when nothing enforces it.
