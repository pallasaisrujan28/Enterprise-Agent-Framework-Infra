# Unit tests for modules/helm-release.
# command = plan, mocked providers, no cluster and no credentials.

mock_provider "helm" {}

variables {
  name      = "example"
  namespace = "default"
  chart     = "example"
}

run "safe_defaults_are_what_you_get_by_saying_nothing" {
  command = plan

  variables {
    chart_version = "1.2.3"
  }

  assert {
    condition     = helm_release.this.wait == true
    error_message = "wait must default on. Off, a release can be created with a failed status while the apply reports success — which is how helm list came to disagree with reality here before."
  }

  assert {
    condition     = helm_release.this.atomic == true
    error_message = "atomic must default on, so a failed release does not stay installed."
  }

  assert {
    condition     = helm_release.this.timeout == 600
    error_message = "the wait must be bounded. An unbounded wait is a hung pipeline with no diagnostic."
  }

  assert {
    condition     = helm_release.this.create_namespace == false
    error_message = "helm must not create namespaces. The cluster-addons layer owns them, along with the default-deny policy and quota a Helm-created namespace would not have."
  }
}

run "the_pinned_version_is_the_one_passed" {
  command = plan

  variables {
    chart_version = "5.26.30"
  }

  assert {
    condition     = helm_release.this.version == "5.26.30"
    error_message = "chart version must be passed through exactly."
  }

  assert {
    condition     = output.inventory.chart_version == "5.26.30"
    error_message = "inventory must record the version that makes the deployment reproducible."
  }
}

run "values_are_rendered_as_yaml_preserving_types" {
  command = plan

  variables {
    chart_version = "1.0.0"
    values = {
      replicas = 3
      enabled  = true
      nested   = { key = "value" }
    }
  }

  # The point of yamlencode over `set`: a number stays a number. Through `set` this would
  # arrive as the string "3", and a chart doing arithmetic on it fails inside a template
  # rather than at plan time.
  #
  # NOTE ON THE PATTERNS: terraform's yamlencode quotes KEYS, so this renders as
  # `"replicas": 3`, not `replicas: 3`. Both are the same YAML document and Helm parses
  # either. The first version of this test matched unquoted keys, failed, and looked like a
  # module defect — it was the assertion encoding an assumption about the formatter.
  #
  # What matters is the VALUE side of the colon, which is what these pin: `3` and `true`
  # unquoted, and quoted only where the input was genuinely a string.
  assert {
    condition     = can(regex("\"replicas\": 3\\n", helm_release.this.values[0]))
    error_message = "a number must render unquoted. Quoted, a chart doing arithmetic on it fails inside a template rather than at plan time."
  }

  assert {
    condition     = can(regex("\"enabled\": true\\n", helm_release.this.values[0]))
    error_message = "a bool must render unquoted."
  }

  assert {
    condition     = can(regex("\"nested\":\\n  \"key\": \"value\"", helm_release.this.values[0]))
    error_message = "nested objects must render as nested YAML, without set's dotted-path escaping. A genuine string stays quoted, which is the contrast that shows types survive."
  }
}

run "empty_values_produce_a_valid_document" {
  command = plan

  variables {
    chart_version = "1.0.0"
    values        = {}
  }

  assert {
    condition     = length(helm_release.this.values) == 1
    error_message = "a single values document is always passed, even when empty."
  }
}

run "wait_can_be_disabled_only_together_with_atomic" {
  command = plan

  variables {
    chart_version = "1.0.0"
    wait          = false
    atomic        = false
  }

  assert {
    condition     = helm_release.this.wait == false && helm_release.this.atomic == false
    error_message = "both may be turned off together for a chart that genuinely cannot be waited on."
  }

  assert {
    condition     = output.inventory.failure_is_visible == false
    error_message = "the inventory must admit when a failure would be invisible, rather than reporting the release as healthy."
  }
}

run "reject_atomic_without_wait" {
  command = plan

  variables {
    chart_version = "1.0.0"
    wait          = false
    atomic        = true
  }

  # A rollback decision cannot be made without waiting to see whether the release became
  # ready, so this combination is incoherent rather than merely unusual.
  expect_failures = [helm_release.this]
}

run "reject_an_unpinned_chart" {
  command = plan

  variables {
    chart_version = "  "
  }

  # An empty version resolves to whatever the repository published most recently, so two
  # applies of identical Terraform can install different software.
  expect_failures = [var.chart_version]
}

run "reject_an_invalid_release_name" {
  command = plan

  variables {
    name          = "Not_A_Valid_Name"
    chart_version = "1.0.0"
  }

  expect_failures = [var.name]
}

run "reject_an_unbounded_timeout" {
  command = plan

  variables {
    chart_version   = "1.0.0"
    timeout_seconds = 0
  }

  expect_failures = [var.timeout_seconds]
}
