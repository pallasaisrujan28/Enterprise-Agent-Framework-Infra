# `lab/` — the fast loop

A cluster you apply and destroy **from your terminal**, in seconds of typing rather than a
dispatched workflow and an approval gate.

```bash
source .local/dev-env.sh

cd lab/cluster && terraform init && terraform apply      # ~15 min, once
aws eks update-kubeconfig --name eaf-lab --region eu-west-2
kubectl get nodes

cd ../apps && terraform init && terraform apply           # ~2 min

# and when you are done for the day
cd ../apps && terraform destroy
cd ../cluster && terraform destroy
```

## Why this exists alongside `workloads/`

`workloads/` is the reviewed path: remote state in the management account, OIDC, plan
artefacts, approval gates, nineteen correctness properties. It is right for something people
depend on, and it is the reason a one-line change has been taking a dispatched workflow and a
round trip.

`lab/` is for experimenting. **State is local.** Your SSO admin credentials are enough, so
nothing goes through GitHub. That single difference is what makes this usable, and it is why
`workloads/` could not simply be pointed at your laptop: its state lives in an account your
credentials get a 403 on.

## What is deliberately given up

Stated plainly, because these are real and they are choices rather than oversights.

| Given up | Consequence |
|---|---|
| **Remote state** | `terraform.tfstate` is a file in `lab/*/`. Delete it and Terraform forgets the cluster exists while AWS keeps billing. It is gitignored — losing the laptop loses the state |
| **No state locking** | Two applies at once corrupt it. You are one person, so this is theoretical |
| **Public API endpoint, `0.0.0.0/0`** | Anyone can reach the Kubernetes API. Authentication still gates it, but the endpoint is public |
| **Inline IAM roles** | Not `modules/iam-role`, so no permissions boundary and no generated naming. Fewer required inputs, faster to change |
| **No approval gate** | `terraform destroy` destroys. Nothing pauses to ask |
| **Your SSO role is cluster-admin directly** | No `OrganizationAccountAccessRole` hop, so `kubectl` works the moment the cluster is up |

Do not copy this layout into `workloads/`. The point of having both is that one is fast and
one is careful.

## Two directories, and why it is not one

A single root module that creates a cluster *and* configures the `kubernetes` provider from
that cluster's outputs cannot plan from an empty state: the provider needs a hostname that
does not exist yet, and Terraform refuses to configure a provider from an unknown value.

That is the same fault (RC2 in the design) that produced the seven hacks this project spent
months unwinding. It is not ceremony — it is the one structural rule worth keeping, and it
costs you one extra `cd`.

## Cost

Roughly **$0.62/hour** while it is up, about $15/day:

| | |
|---|---|
| EKS control plane | $0.10/hr |
| 2 × `m6i.xlarge` (4 vCPU / 16 GiB) | $0.444/hr |
| NAT gateway | $0.05/hr |
| gp3 volumes | a few cents |

Bigger nodes than `workloads/` used, because the memory and RL stack does not fit two
`m6i.large`. `terraform destroy` takes it to roughly zero — the ECR repositories in
`workloads/dev/registry` are the only thing that persists, and they cost pennies.

## Checking nothing was left behind

```bash
make teardown-check
```

Works unchanged here. It queries AWS directly rather than reading Terraform state, so it does
not care which root module created a resource — which is exactly what you want from a leak
check.
