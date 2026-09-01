# `workloads/dev/registry` — L0

Container repositories, and nothing else. **This layer is not destroyed with the others.**

```
Actions → Apply workloads layer → target: dev, layer: registry
```

## Why it is a separate layer

The operating rhythm here is **destroy-and-rebuild**: the cluster is torn down whenever it is
not in use, because it costs about **$0.39/hour** to leave running. That makes "what survives
a teardown?" a design question rather than an afterthought.

Images should survive. The agent image is built by a workflow in the **application**
repository, so losing it means remembering to trigger a second repository's pipeline and
waiting for it. Keeping it costs roughly **$0.10 per GB-month**. A layer destroyed weekly is
the wrong home for something with those economics.

**The split is about lifetime, not dependency.** Nothing here depends on the cluster and the
cluster does not depend on this. They are simply destroyed on different schedules, and
Terraform has no way to express that other than a layer boundary.

## How that is enforced

Two things, neither of them a comment:

**`registry` is not an option in `destroy-workloads.yml`.** It is an option in
`apply-workloads.yml`. Terraform cannot express "this layer outlives that one", so the only
place the distinction can live is in what the workflow offers. Destroying it stays possible
and requires someone to mean it.

**`force_delete = false`**, against what the platform layer used when it owned these. A
destroy that refuses to proceed while images are present is not an obstacle — it is the guard
working.

## The rebuild sequence

```
  registry        ← already exists; skip it
     │
  platform        ← VPC, cluster, node group, add-ons     ~15-20 min
     │
  cluster-addons  ← namespaces, StorageClass              ~30 sec
     │
  apps            ← workloads
```

And the teardown, in reverse:

```
  apps  →  cluster-addons  →  platform
                                        registry stays
```

`cluster-addons` **must** go before `platform`: its provider needs a reachable Kubernetes
endpoint, and if the cluster is already gone its own destroy cannot run.

## Immutable tags

All three repositories are `IMMUTABLE`, which fixes a defect this repository already had.

The previous `eaf/agent` was `IMMUTABLE` while its build workflow pushed both `:${sha}` *and*
`:latest` on every run. An immutable repository refuses to move an existing tag, so the
**first** push succeeded and every one after failed. The `tools/*` repositories had the
mirror problem — `MUTABLE` with `:latest`, so nothing recorded which image was running.

**Nothing deploys `:latest`.** Every reference is a commit SHA or a digest. That is Property 5,
and `IMMUTABLE` enforces it rather than documenting it.

## Lifecycle

Untagged images expire after 7 days; the 30 most recent tagged images are kept.

**Both rules are needed on an immutable repository.** The untagged rule alone would rarely
fire, because an immutable tag is never orphaned by a re-push. The count rule alone leaves no
bound, because every build adds a tag that is never replaced.

## Outputs

`repository_urls`, `repository_arns`, `registry_id`, `registry_inventory`.

`repository_urls` is read by the apps layer through `terraform_remote_state`, and by the
application repository's build workflow. Pass it rather than reconstructing
`<account>.dkr.ecr.<region>.amazonaws.com/<name>` — a reconstructed string creates no
dependency edge, so a change breaks the consumer silently at apply.

`registry_inventory.all_image_tags_immutable` is one boolean for the property a trustworthy
rollback depends on.
