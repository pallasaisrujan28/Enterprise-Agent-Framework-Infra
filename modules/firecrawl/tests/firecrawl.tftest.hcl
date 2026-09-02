# Unit tests for modules/firecrawl.
# command = plan, mocked providers, no cluster and no credentials.
#
# The capacity assertions are the point of this file. Upstream's defaults ask for roughly
# 10,250m CPU against a cluster with about 2,680m free, so "does it fit?" is not a detail here
# — it is the difference between a working deployment and eight Pending pods, which is the
# state this cluster was actually in before the rebuild.

mock_provider "kubernetes" {}
mock_provider "random" {}

variables {
  namespace = "tools"
  registry  = "718438899462.dkr.ecr.eu-west-2.amazonaws.com"
  image_tag = "0123456789abcdef0123456789abcdef01234567"
}

run "the_default_sizing_fits_the_budget" {
  command = plan

  assert {
    condition     = output.inventory.capacity.cpu_millicores_requested <= 1600
    error_message = "default CPU requests must fit the 1600m budget. Roughly 2,680m is free on this cluster after kube-system and Neo4j."
  }

  assert {
    condition     = output.inventory.capacity.memory_mib_requested <= 6144
    error_message = "default memory requests must fit the 6144Mi budget."
  }

  # The reduction is the whole reason this module differs from upstream's chart, so it is
  # pinned rather than left as a comment that can drift from the numbers.
  assert {
    condition     = output.inventory.capacity.cpu_millicores_requested < output.inventory.capacity.upstream_default_cpu_millicores / 5
    error_message = "the sizing must remain at least five times smaller than upstream's default, which does not fit two m6i.large."
  }
}

run "raising_replicas_past_the_budget_fails_the_plan" {
  command = plan

  # nuq-worker is the one upstream ships at five, so it is the realistic way this budget gets
  # blown. A check block turns that into a plan failure with the arithmetic in the message,
  # rather than pods sitting Pending with `Insufficient cpu`.
  variables {
    workloads = {
      api = {
        replicas = 1
        cpu      = "300m"
        memory   = "1Gi"
        image    = "api"
        port     = 3002
      }
      nuq-worker = {
        replicas = 5
        cpu      = "1000m"
        memory   = "3Gi"
        image    = "api"
      }
    }
  }

  expect_failures = [check.requests_fit_the_declared_budget]
}

run "an_unparseable_request_fails_rather_than_undercounting" {
  command = plan

  # `2G` is upstream's own unit and is NOT `2Gi`. Accepting it silently would sum it as zero,
  # so the budget check would pass by undercounting — a check computed from a wrong total is
  # worse than no check.
  variables {
    workloads = {
      api = {
        replicas = 1
        cpu      = "300m"
        memory   = "2G"
        image    = "api"
        port     = 3002
      }
    }
  }

  expect_failures = [check.requests_fit_the_declared_budget]
}

run "every_worker_upstream_runs_is_present" {
  command = plan

  # Omitting a worker is worse than setting it to zero replicas, because nothing shows it is
  # missing. An earlier draft of this module silently dropped two of them.
  assert {
    condition = length(setsubtract(
      ["api", "worker", "extract-worker", "nuq-worker", "nuq-prefetch-worker", "cclog-worker",
      "playwright", "redis", "rabbitmq", "nuq-postgres"],
      keys(var.workloads)
    )) == 0
    error_message = "a workload upstream's chart runs is absent from the default map. Set replicas to 0 deliberately if it is not wanted, so the omission is visible."
  }
}

run "images_are_pinned_to_the_commit_sha" {
  command = plan

  assert {
    condition     = kubernetes_deployment_v1.this["api"].spec[0].template[0].spec[0].container[0].image == "718438899462.dkr.ecr.eu-west-2.amazonaws.com/tools/firecrawl:0123456789abcdef0123456789abcdef01234567"
    error_message = "the API image must be the ECR repository at the commit SHA, not a moving tag."
  }

  assert {
    condition     = kubernetes_deployment_v1.this["nuq-postgres"].spec[0].template[0].spec[0].container[0].image == "718438899462.dkr.ecr.eu-west-2.amazonaws.com/tools/firecrawl-nuq-postgres:0123456789abcdef0123456789abcdef01234567"
    error_message = "the queue database must use the EAF-built nuq-postgres image. Stock postgres accepts the connection and then fails at query time, because upstream builds this image with the schema the queue needs."
  }
}

run "reject_a_moving_image_tag" {
  command = plan

  variables {
    image_tag = "latest"
  }

  expect_failures = [var.image_tag]
}

run "no_service_is_a_load_balancer" {
  command = plan

  # The API has no authentication, so a LoadBalancer would publish an unauthenticated scraping
  # service — and leak an AWS resource no Terraform state knows about.
  assert {
    condition     = alltrue([for k, s in kubernetes_service_v1.this : s.spec[0].type == "ClusterIP"])
    error_message = "every service must be ClusterIP."
  }

  assert {
    condition     = output.inventory.access.creates_load_balancer == false
    error_message = "no load balancer may be created."
  }

  # Only the workloads that others reach by DNS get a Service. The workers do not listen.
  assert {
    condition     = length(kubernetes_service_v1.this) == 5
    error_message = "exactly the five listening workloads get a Service: api, playwright, redis, rabbitmq, nuq-postgres."
  }
}

run "the_api_is_reachable_only_from_named_namespaces" {
  command = plan

  variables {
    allowed_client_namespaces = ["eaf"]
  }

  assert {
    condition     = one(kubernetes_network_policy_v1.allow_api).spec[0].ingress[0].ports[0].port == "3002"
    error_message = "only the API port may be opened to other namespaces."
  }

  assert {
    condition     = length(one(kubernetes_network_policy_v1.allow_api).spec[0].ingress[0].from) == 1
    error_message = "one from block per allowed namespace."
  }

  # Separate from the API policy on purpose: this one is about the stack functioning, that one
  # is about who may use it, and merging them means a change to either risks the other.
  assert {
    condition     = length(kubernetes_network_policy_v1.allow_internal) == 1
    error_message = "the components must be allowed to reach each other, or the stack cannot function behind the namespace's default-deny."
  }
}

run "authentication_is_reported_as_absent_rather_than_implied" {
  command = plan

  # Firecrawl self-hosted has no API authentication and cannot gain it without the Supabase
  # stack. Recording that plainly is the point: the NetworkPolicy is the only control, not a
  # second layer behind a key.
  assert {
    condition     = output.inventory.access.api_authentication_enabled == false
    error_message = "the inventory must state that the API is unauthenticated."
  }

  assert {
    condition     = output.inventory.capabilities.search_backend == "duckduckgo"
    error_message = "search falls back to DuckDuckGo with no key and no SearXNG — verified in apps/api/src/search/index.ts."
  }

  assert {
    condition     = contains(output.inventory.capabilities.unsupported, "screenshots")
    error_message = "screenshots need Fire Engine, which is not in the self-hosted distribution, and that limit should be recorded rather than discovered."
  }
}

run "no_policy_when_nothing_would_enforce_it" {
  command = plan

  variables {
    network_policy_enforced   = false
    allowed_client_namespaces = ["eaf"]
  }

  assert {
    condition     = length(kubernetes_network_policy_v1.allow_api) == 0
    error_message = "no policy may be created when nothing enforces it — with authentication off, an inert policy implies protection that does not exist."
  }

  assert {
    condition     = output.inventory.access.policy_enforced == false
    error_message = "the inventory must admit nothing is enforced."
  }
}

run "the_postgres_password_is_generated_and_slash_free" {
  command = plan

  # Upstream's own documentation flags postgres/postgres as local-development only.
  assert {
    condition     = random_password.postgres.special == false
    error_message = "the password must be alphanumeric — it travels through connection strings and shell environments."
  }

  assert {
    condition     = contains(keys(kubernetes_secret_v1.env.data), "POSTGRES_PASSWORD")
    error_message = "the generated password must be in a Secret, not the ConfigMap."
  }

  assert {
    condition     = contains(keys(kubernetes_config_map_v1.env.data), "POSTGRES_PASSWORD") == false
    error_message = "the password must NOT be in the ConfigMap, which is not a secret store."
  }
}

run "the_queue_volume_does_not_block_the_apply" {
  command = plan

  # gp3 binds WaitForFirstConsumer, so waiting for the claim to bind waits for a pod that this
  # same apply has not created yet.
  assert {
    condition     = kubernetes_persistent_volume_claim_v1.postgres.wait_until_bound == false
    error_message = "waiting for the claim to bind deadlocks against WaitForFirstConsumer."
  }

  assert {
    condition     = output.inventory.storage.holds_durable_data == false
    error_message = "the queue holds in-flight jobs, not crawl output, and the inventory should say so — losing it loses queued work and nothing durable."
  }
}

run "reject_an_invalid_name" {
  command = plan

  variables {
    name = "FireCrawl_API"
  }

  expect_failures = [var.name]
}
