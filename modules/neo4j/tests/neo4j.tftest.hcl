# Unit tests for modules/neo4j.
# command = plan, mocked providers, no cluster and no credentials.
#
# Several of these pin details of the UPSTREAM CHART's contract rather than this module's
# own logic — the NEO4J_AUTH key name, the `neo4j/` value prefix, ClusterIP over the chart's
# LoadBalancer default. That is deliberate. Each was read out of the chart's templates, and
# each fails in a way that names something other than the real cause: a missing key reads as
# a password policy, and the LoadBalancer default reads as a working deployment right up to
# the AWS bill.

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "random" {}

variables {
  namespace = "memory"
}

run "the_secret_matches_the_format_the_chart_demands" {
  command = plan

  # THE THREE REQUIREMENTS, from the chart's _helpers.tpl:
  #   the Secret must exist, it must contain key NEO4J_AUTH, and that value must start
  #   with "neo4j/". Any one of them wrong fails the release with a message that points
  #   somewhere else.
  assert {
    condition     = contains(keys(kubernetes_secret_v1.auth.data), "NEO4J_AUTH")
    error_message = "the key must be exactly NEO4J_AUTH. Anything else fails with 'Secret must contain key NEO4J_AUTH'."
  }

  assert {
    condition     = startswith(kubernetes_secret_v1.auth.data["NEO4J_AUTH"], "neo4j/")
    error_message = "the value must be user/password, not a bare password. A bare password fails with 'must start with the characters neo4j/', which reads like a password policy rather than a format requirement."
  }

  assert {
    condition     = kubernetes_secret_v1.auth.type == "Opaque"
    error_message = "the secret type must be Opaque."
  }
}

run "the_generated_password_contains_no_slash" {
  command = plan

  # Not cosmetic. The chart recovers the password with `cut -d '/' -f2`, so a slash
  # truncates it silently: the release installs and authentication then fails against a
  # credential nobody typed. random_password with special=false is what guarantees this.
  assert {
    condition     = random_password.neo4j.special == false
    error_message = "the password must be alphanumeric. The chart parses it with cut -d '/', so a slash truncates it and authentication fails against a value nothing generated."
  }

  assert {
    condition     = random_password.neo4j.length >= 16
    error_message = "the password must be at least 16 characters."
  }
}

run "authentication_cannot_be_disabled" {
  command = plan

  # Closing finding 6 structurally rather than by remembering a flag. Setting
  # passwordFromSecret and auth_enabled=false together is a hard template failure upstream,
  # so this module is incapable of producing an unauthenticated database.
  #
  # The strong form of this is checked by the chart, not here: `dbms.security.auth_enabled`
  # is never set by this module, and setting it to false alongside a password fails the
  # release outright. So there is no configuration of these inputs that yields an
  # unauthenticated database, which is why there is no input to test for.
  assert {
    condition     = output.inventory.access.authentication_enabled == true
    error_message = "authentication must be on. Without it, reaching the network is sufficient to read and write everything the agent has been told."
  }
}

run "the_service_is_never_a_load_balancer" {
  command = plan

  # The chart's default is LoadBalancer, which on EKS means an internet-facing NLB in front
  # of the database: bolt exposed publicly, ~$19.32/month, and ENIs that later fail the VPC
  # destroy with DependencyViolation.
  #
  # THIS FIRST ASSERTION IS THE ONE THAT MATTERS. It reads the YAML the release actually
  # receives. The inventory assertions below are a description this module writes about
  # itself, and an earlier version of this test checked only those — so flipping the chart
  # value to LoadBalancer changed nothing that any test could see. Found by mutation.
  assert {
    condition     = can(regex("\"type\": \"ClusterIP\"", module.release.rendered_values))
    error_message = "the values sent to Helm must set ClusterIP. The chart defaults to LoadBalancer, which puts an internet-facing NLB in front of the database and leaks it on teardown."
  }

  assert {
    condition     = can(regex("LoadBalancer", module.release.rendered_values)) == false
    error_message = "the string LoadBalancer must not appear anywhere in the rendered values."
  }

  assert {
    condition     = output.inventory.access.service_type == "ClusterIP"
    error_message = "the service must be ClusterIP."
  }

  assert {
    condition     = output.inventory.access.internet_reachable == false
    error_message = "the database must not be reachable from the internet."
  }

  assert {
    condition     = output.inventory.access.creates_load_balancer == false
    error_message = "no load balancer may be created. One created by a chart is invisible to Terraform and leaks on teardown."
  }

  assert {
    condition     = output.inventory.access.chart_default_was == "LoadBalancer"
    error_message = "the inventory must record what the chart would have done, so the override being lost is visible."
  }
}

run "the_volume_is_sized_and_on_a_named_class" {
  command = plan

  variables {
    storage_size       = "20Gi"
    storage_class_name = "gp3"
  }

  assert {
    condition     = output.inventory.storage.size == "20Gi"
    error_message = "the requested size must be what was asked for, not the chart's 100Gi default."
  }

  assert {
    condition     = output.inventory.storage.class_name == "gp3"
    error_message = "the storage class must be named explicitly rather than inherited from whichever class is default."
  }

  assert {
    condition     = output.inventory.storage.data_is_destroyed_with_this_module == true
    error_message = "the inventory must state plainly that destroying this destroys the graph."
  }
}

run "bolt_not_neo4j_scheme" {
  command = plan

  # neo4j:// asks for a routing table. A single-instance Community deployment has none, and
  # the client error talks about routing being unavailable rather than about the scheme.
  assert {
    condition     = startswith(output.bolt_uri, "bolt://")
    error_message = "the URI must use bolt://. neo4j:// requests cluster routing discovery, which a standalone instance cannot answer."
  }

  assert {
    condition     = endswith(output.bolt_uri, ":7687")
    error_message = "the bolt port must be 7687."
  }

  assert {
    condition     = output.bolt_uri == "bolt://neo4j.memory.svc.cluster.local:7687"
    error_message = "the address must be derived from name and namespace, so it cannot drift from the objects the chart creates."
  }
}

run "only_bolt_is_opened_never_the_http_browser" {
  command = plan

  variables {
    allowed_client_namespaces = ["eaf"]
  }

  assert {
    condition     = length(one(kubernetes_network_policy_v1.allow_bolt).spec[0].ingress[0].ports) == 1
    error_message = "exactly one port must be opened."
  }

  assert {
    condition     = one(kubernetes_network_policy_v1.allow_bolt).spec[0].ingress[0].ports[0].port == "7687"
    error_message = "only 7687 may be opened. 7474 is the HTTP browser and is reached by port-forward, which does not traverse a Service."
  }

  assert {
    condition     = one(kubernetes_network_policy_v1.allow_bolt).spec[0].policy_types == tolist(["Ingress"])
    error_message = "only Ingress may be restricted. Denying egress here would break DNS and present as a broken CoreDNS."
  }
}

run "named_namespaces_and_the_local_one_are_admitted" {
  command = plan

  variables {
    allowed_client_namespaces = ["eaf", "tools"]
    allow_same_namespace      = true
  }

  # Two named namespaces plus the local one.
  assert {
    condition     = length(one(kubernetes_network_policy_v1.allow_bolt).spec[0].ingress[0].from) == 3
    error_message = "each allowed namespace plus the local one needs its own from block."
  }

  assert {
    condition     = output.inventory.access.allowed_namespaces == tolist(["eaf", "memory", "tools"])
    error_message = "the inventory must list every namespace that can reach the database, sorted, including its own."
  }
}

run "no_policy_when_nothing_would_enforce_it" {
  command = plan

  variables {
    network_policy_enforced   = false
    allowed_client_namespaces = ["eaf"]
  }

  # Worse than useless if created: the namespace's default-deny is equally unenforced, so
  # the database is reachable from anywhere while every object looks correct.
  assert {
    condition     = length(kubernetes_network_policy_v1.allow_bolt) == 0
    error_message = "no policy may be created when nothing enforces it — it would imply protection that does not exist."
  }

  assert {
    condition     = output.inventory.access.policy_enforced == false
    error_message = "the inventory must admit that nothing is enforced."
  }
}

run "no_policy_and_no_access_before_a_consumer_exists" {
  command = plan

  variables {
    allowed_client_namespaces = []
    allow_same_namespace      = false
  }

  assert {
    condition     = length(kubernetes_network_policy_v1.allow_bolt) == 0
    error_message = "with nothing allowed there is no policy to create."
  }

  assert {
    condition     = output.inventory.access.reachable_by_anything == false
    error_message = "a database nothing can reach is a valid state before a consumer exists, and must be reported as such rather than as a failure."
  }
}

run "the_chart_version_is_pinned_to_the_lts_line" {
  command = plan

  assert {
    condition     = startswith(var.chart_version, "5.26.")
    error_message = "the default must stay on the 5.26 LTS line: supported to June 2028, and the floor Graphiti documents. The chart's newer calendar-versioned releases are not documented against Graphiti."
  }
}

run "consumers_get_a_secret_reference_not_a_password" {
  command = plan

  assert {
    condition     = output.password_secret_key == "NEO4J_AUTH"
    error_message = "the key a consumer reads must be named."
  }

  assert {
    condition     = output.username == "neo4j"
    error_message = "the username is fixed by the chart's NEO4J_AUTH format."
  }

  assert {
    condition     = output.password_secret_name == "neo4j-auth"
    error_message = "the secret name must be derived from the release name so a consumer can reference it."
  }
}

run "reject_a_bad_storage_size" {
  command = plan

  variables {
    storage_size = "10 gigabytes"
  }

  expect_failures = [var.storage_size]
}

run "reject_a_short_password" {
  command = plan

  variables {
    password_length = 8
  }

  expect_failures = [var.password_length]
}

run "reject_an_invalid_name" {
  command = plan

  variables {
    name = "Neo4J_Memory"
  }

  expect_failures = [var.name]
}
